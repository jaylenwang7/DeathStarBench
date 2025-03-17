#ifndef SOCIAL_NETWORK_MICROSERVICES_SRC_UTILS_MONGODB_H_
#define SOCIAL_NETWORK_MICROSERVICES_SRC_UTILS_MONGODB_H_

#include <mongoc.h>
#include <bson/bson.h>
#include <atomic>
#include <chrono>
#include <mutex>

#define SERVER_SELECTION_TIMEOUT_MS 30
#define PING_TIMEOUT_MS 20
#define CIRCUIT_BREAKER_THRESHOLD 2
#define CIRCUIT_RESET_TIME_MS 5000

namespace social_network {

class MongoCircuitBreaker {
private:
    std::atomic<int> failure_count{0};
    std::atomic<bool> circuit_open{false};
    std::chrono::time_point<std::chrono::steady_clock> reset_time;
    std::mutex mutex;

public:
    bool isOpen() {
        if (circuit_open) {
            // Check if it's time to try again
            std::lock_guard<std::mutex> lock(mutex);
            auto now = std::chrono::steady_clock::now();
            if (now > reset_time) {
                // Allow one request to try the connection again
                circuit_open = false;
                failure_count = 0;
                return false;
            }
            return true;
        }
        return false;
    }

    void recordSuccess() {
        failure_count = 0;
    }

    void recordFailure() {
        int current = ++failure_count;
        if (current >= CIRCUIT_BREAKER_THRESHOLD) {
            std::lock_guard<std::mutex> lock(mutex);
            circuit_open = true;
            reset_time = std::chrono::steady_clock::now() + 
                         std::chrono::milliseconds(CIRCUIT_RESET_TIME_MS);
        }
    }
};

// Global circuit breaker instance
MongoCircuitBreaker mongodb_circuit;

mongoc_client_pool_t* init_mongodb_client_pool(
    const json &config_json,
    const std::string &service_name,
    uint32_t max_size
) {
    std::string addr = config_json[service_name + "-mongodb"]["addr"];
    int port = config_json[service_name + "-mongodb"]["port"];
    std::string uri_str = "mongodb://" + addr + ":" +
        std::to_string(port) + "/?appname=" + service_name + "-service";
    uri_str += "&" MONGOC_URI_SERVERSELECTIONTIMEOUTMS "="
        + std::to_string(SERVER_SELECTION_TIMEOUT_MS);

    mongoc_init();
    bson_error_t error;
    mongoc_uri_t *mongodb_uri =
        mongoc_uri_new_with_error(uri_str.c_str(), &error);

    if (!mongodb_uri) {
        LOG(fatal) << "Error: failed to parse URI" << std::endl
                << "error message: " << std::endl
                << uri_str << std::endl
                << error.message<< std::endl;
        return nullptr;
    } else {
        if (config_json["ssl"]["enabled"]) {
            std::string ca_file = config_json["ssl"]["caPath"];

            mongoc_uri_set_option_as_bool(mongodb_uri, MONGOC_URI_TLS, true);
            mongoc_uri_set_option_as_utf8(mongodb_uri, MONGOC_URI_TLSCAFILE, ca_file.c_str());
            mongoc_uri_set_option_as_bool(mongodb_uri, MONGOC_URI_TLSALLOWINVALIDHOSTNAMES, true);
        }

        mongoc_client_pool_t *client_pool= mongoc_client_pool_new(mongodb_uri);
        mongoc_client_pool_max_size(client_pool, max_size);
        return client_pool;
    }
}

// Fast validation function for MongoDB connections
bool validateMongoConnection(mongoc_client_t *client) {
    // Check if circuit breaker is open
    if (mongodb_circuit.isOpen()) {
        return false;
    }
    
    // Create command for ping
    bson_t *ping = BCON_NEW("ping", BCON_INT32(1));
    
    // Create options with timeout
    bson_t *opts = BCON_NEW("maxTimeMS", BCON_INT32(PING_TIMEOUT_MS));
    
    bson_t reply;
    bson_error_t error;
    
    // Use command_with_opts which accepts options
    bool valid = mongoc_client_command_with_opts(
        client,
        "admin",
        ping,
        NULL,  // read_prefs can be NULL
        opts,  // options with maxTimeMS
        &reply,
        &error);
    
    bson_destroy(ping);
    bson_destroy(opts);
    bson_destroy(&reply);
    
    if (valid) {
        mongodb_circuit.recordSuccess();
    } else {
        mongodb_circuit.recordFailure();
        LOG(warning) << "MongoDB connection validation failed: " << error.message;
    }
    
    return valid;
}

// Safe version of mongo_client_pool_pop_safe that includes validation
mongoc_client_t* mongo_client_pool_pop_safe(mongoc_client_pool_t* pool) {
    // Fast fail if circuit is open
    if (mongodb_circuit.isOpen()) {
        LOG(warning) << "MongoDB circuit breaker open, failing fast";
        return nullptr;
    }
    
    mongoc_client_t* client = mongo_client_pool_pop(pool);
    if (!client) {
        return nullptr;
    }
    
    // Validate connection is healthy
    if (!validateMongoConnection(client)) {
        mongoc_client_pool_push(pool, client);
        return nullptr;
    }
    
    return client;
}

bool CreateIndex(
    mongoc_client_t *client,
    const std::string &db_name,
    const std::string &index,
    bool unique) {
    mongoc_database_t *db;
    bson_t keys;
    char *index_name;
    bson_t *create_indexes;
    bson_t reply;
    bson_error_t error;
    bool r;

    db = mongoc_client_get_database(client, db_name.c_str());
    bson_init (&keys);
    BSON_APPEND_INT32(&keys, index.c_str(), 1);
    index_name = mongoc_collection_keys_to_index_string(&keys);
    create_indexes = BCON_NEW (
        "createIndexes", BCON_UTF8(db_name.c_str()),
        "indexes", "[", "{",
            "key", BCON_DOCUMENT (&keys),
            "name", BCON_UTF8 (index_name),
            "unique", BCON_BOOL(unique),
        "}", "]");
    r = mongoc_database_write_command_with_opts (
        db, create_indexes, NULL, &reply, &error);
    if (!r) {
        LOG(error) << "Error in createIndexes: " << error.message;
    }
    bson_free (index_name);
    bson_destroy (&reply);
    bson_destroy (create_indexes);
    mongoc_database_destroy(db);

    return r;
}

} // namespace social_network

#endif //SOCIAL_NETWORK_MICROSERVICES_SRC_UTILS_MONGODB_H_