#ifndef SOCIAL_NETWORK_MICROSERVICES_SRC_UTILS_REDIS_H_
#define SOCIAL_NETWORK_MICROSERVICES_SRC_UTILS_REDIS_H_

#include <sw/redis++/redis++.h>
#include <chrono>

using namespace sw::redis;
namespace social_network {

struct RedisConfig {
  ConnectionOptions connection_opts;
  ConnectionPoolOptions pool_opts;
  std::chrono::milliseconds cmd_timeout;
};

RedisConfig init_redis_config(
	const json& config_json,
	const std::string& service_name,
	const std::string& config_prefix = ""
) {
	RedisConfig config;
	const std::string prefix = config_prefix.empty() ? service_name + "-redis" : config_prefix;
	
	config.connection_opts.host = config_json[prefix]["addr"];
	config.connection_opts.port = config_json[prefix]["port"];
	
	if (config_json["ssl"]["enabled"]) {
		std::string ca_file = config_json["ssl"]["caPath"];
		config.connection_opts.tls.enabled = true;
		config.connection_opts.tls.cacert = ca_file.c_str();
	}
	
	config.pool_opts.size = config_json[prefix]["connections"];
	config.pool_opts.wait_timeout = std::chrono::milliseconds(config_json[prefix]["timeout_ms"]);
	config.pool_opts.connection_lifetime = std::chrono::milliseconds(config_json[prefix]["keepalive_ms"]);
	
	// Default operation timeout of 100ms if not specified
	config.cmd_timeout = std::chrono::milliseconds(
		config_json[prefix].contains("operation_timeout_ms") ? 
		config_json[prefix]["operation_timeout_ms"].get<int>() : 100);
	
	return config;
}

Redis init_redis_client_pool(const json& config_json, const std::string& service_name) {
	auto config = init_redis_config(config_json, service_name);
	auto redis = Redis(config.connection_opts, config.pool_opts);
	redis.command_timeout(config.cmd_timeout);
	return redis;
}

RedisCluster init_redis_cluster_client_pool(const json& config_json, const std::string& service_name) {
	auto config = init_redis_config(config_json, service_name);
	auto redis = RedisCluster(config.connection_opts, config.pool_opts);
	redis.command_timeout(config.cmd_timeout);
	return redis;
}

Redis init_redis_replica_client_pool(const json& config_json, const std::string& service_name) {
	auto config = init_redis_config(config_json, service_name, service_name);
	auto redis = Redis(config.connection_opts, config.pool_opts);
	redis.command_timeout(config.cmd_timeout);
	return redis;
}


} // namespace social_network

#endif //SOCIAL_NETWORK_MICROSERVICES_SRC_UTILS_REDIS_H_
