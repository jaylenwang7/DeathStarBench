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

// Safe version of mongoc_client_pool_pop that includes validation
mongoc_client_t* mongo_client_pool_pop_safe(mongoc_client_pool_t* pool) {
    // Fast fail if circuit is open
    if (mongodb_circuit.isOpen()) {
        LOG(warning) << "MongoDB circuit breaker open, failing fast";
        return nullptr;
    }
    
    mongoc_client_t* client = mongoc_client_pool_pop(pool);
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

bool IndexExists(mongoc_client_t *client, const std::string &db_name, 
                 const std::string &collection_name, const std::string &index_name) {
    mongoc_database_t *db = mongoc_client_get_database(client, db_name.c_str());
    mongoc_collection_t *collection = mongoc_database_get_collection(db, collection_name.c_str());
    
    mongoc_cursor_t *cursor = mongoc_collection_find_indexes_with_opts(collection, NULL);
    const bson_t *doc;
    bool exists = false;
    
    while (mongoc_cursor_next(cursor, &doc)) {
        bson_iter_t iter;
        if (bson_iter_init_find(&iter, doc, "name") && BSON_ITER_HOLDS_UTF8(&iter)) {
            const char *name = bson_iter_utf8(&iter, NULL);
            if (strcmp(name, index_name.c_str()) == 0) {
                exists = true;
                break;
            }
        }
    }
    
    mongoc_cursor_destroy(cursor);
    mongoc_collection_destroy(collection);
    mongoc_database_destroy(db);
    return exists;
}

bool CreateIndex(
    mongoc_client_t *client,
    const std::string &db_name,
    const std::string &index_field,
    bool unique) {
    
    if (!client) {
        LOG(error) << "CreateIndex: client is null";
        return false;
    }
    
    // Generate standard MongoDB index name (field_1, field_-1, etc.)
    std::string index_name = index_field + "_1";
    std::string collection_name = GetCollectionName(db_name);
    
    LOG(info) << "CreateIndex: Creating " << (unique ? "unique" : "non-unique") 
              << " index '" << index_name << "' on field '" << index_field 
              << "' in " << db_name << "." << collection_name;
    
    // STEP 1: Check if index already exists
    try {
        if (IndexExists(client, db_name, collection_name, index_name)) {
            LOG(info) << "CreateIndex: Index '" << index_name << "' already exists, skipping creation";
            return true;
        }
        
        // Also check for non-unique version if we're trying to create unique
        if (unique && IndexExists(client, db_name, collection_name, index_field + "_non_unique")) {
            LOG(info) << "CreateIndex: Non-unique version of index already exists: '" 
                      << index_field << "_non_unique'";
            LOG(warning) << "CreateIndex: Continuing with existing non-unique index instead of creating unique";
            return true;
        }
    } catch (...) {
        LOG(warning) << "CreateIndex: Failed to check existing indexes, proceeding with creation attempt";
    }
    
    // STEP 2: Attempt to create the requested index
    mongoc_database_t *db = mongoc_client_get_database(client, db_name.c_str());
    if (!db) {
        LOG(error) << "CreateIndex: Failed to get database '" << db_name << "'";
        return false;
    }
    
    bson_t keys;
    bson_t *create_indexes = nullptr;
    bson_t reply;
    bson_error_t error;
    bool success = false;
    
    bson_init(&keys);
    BSON_APPEND_INT32(&keys, index_field.c_str(), 1);
    
    // Try to create the requested index
    create_indexes = BCON_NEW(
        "createIndexes", BCON_UTF8(collection_name.c_str()),
        "indexes", "[", "{",
            "key", BCON_DOCUMENT(&keys),
            "name", BCON_UTF8(index_name.c_str()),
            "unique", BCON_BOOL(unique),
        "}", "]");
    
    LOG(debug) << "CreateIndex: Attempting to create " << (unique ? "unique" : "non-unique") << " index";
    
    success = mongoc_database_write_command_with_opts(db, create_indexes, NULL, &reply, &error);
    
    // STEP 3: Handle different types of failures intelligently
    if (!success) {
        bool is_duplicate_key_error = (strstr(error.message, "E11000") != NULL || 
                                     strstr(error.message, "duplicate key") != NULL);
        bool is_index_exists_error = (strstr(error.message, "already exists") != NULL ||
                                    strstr(error.message, "IndexOptionsConflict") != NULL);
        
        if (is_index_exists_error) {
            // Index already exists (race condition with another replica)
            LOG(info) << "CreateIndex: Index creation failed because index already exists (race condition)";
            LOG(info) << "CreateIndex: This is normal when multiple replicas start simultaneously";
            success = true;  // Treat as success
            
        } else if (is_duplicate_key_error && unique) {
            // Cannot create unique index due to duplicate data
            LOG(warning) << "CreateIndex: Cannot create unique index due to duplicate data: " << error.message;
            LOG(warning) << "CreateIndex: Attempting to create non-unique index as fallback";
            
            // Clean up first attempt
            bson_destroy(create_indexes);
            bson_destroy(&reply);
            
            // STEP 4: Fallback to non-unique index
            create_indexes = BCON_NEW(
                "createIndexes", BCON_UTF8(collection_name.c_str()),
                "indexes", "[", "{",
                    "key", BCON_DOCUMENT(&keys),
                    "name", BCON_UTF8((index_field + "_non_unique").c_str()),
                    "unique", BCON_BOOL(false),
                "}", "]");
            
            success = mongoc_database_write_command_with_opts(db, create_indexes, NULL, &reply, &error);
            
            if (success) {
                LOG(warning) << "CreateIndex: Successfully created non-unique index '" 
                            << index_field << "_non_unique'";
                LOG(warning) << "CreateIndex: IMPORTANT: You should clean up duplicate data and recreate as unique index";
                LOG(warning) << "CreateIndex: Service will continue with reduced data consistency guarantees";
            } else {
                LOG(error) << "CreateIndex: Failed to create even non-unique index: " << error.message;
            }
            
        } else if (is_duplicate_key_error && !unique) {
            // This shouldn't happen for non-unique indexes, but handle it
            LOG(error) << "CreateIndex: Unexpected duplicate key error for non-unique index: " << error.message;
            
        } else {
            // Other types of errors (permissions, network, etc.)
            LOG(error) << "CreateIndex: Failed to create index due to: " << error.message;
            
            // For some errors, we might want to retry or continue anyway
            if (strstr(error.message, "timeout") != NULL || 
                strstr(error.message, "network") != NULL ||
                strstr(error.message, "connection") != NULL) {
                LOG(warning) << "CreateIndex: Network/timeout error - service might still function without optimal indexing";
                // Could decide to return true here to allow service to continue
            }
        }
    } else {
        LOG(info) << "CreateIndex: Successfully created " << (unique ? "unique" : "non-unique") 
                  << " index '" << index_name << "'";
    }
    
    // STEP 5: Cleanup and return
    if (create_indexes) bson_destroy(create_indexes);
    bson_destroy(&reply);
    mongoc_database_destroy(db);
    
    return success;
}

} // namespace social_network

#endif //SOCIAL_NETWORK_MICROSERVICES_SRC_UTILS_MONGODB_H_