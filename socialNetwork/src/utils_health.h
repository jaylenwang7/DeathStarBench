#ifndef SOCIAL_NETWORK_MICROSERVICES_UTILS_HEALTH_H
#define SOCIAL_NETWORK_MICROSERVICES_UTILS_HEALTH_H

#include <atomic>
#include <memory>
#include <pistache/endpoint.h>
#include <pistache/router.h>
#include "logger.h"

namespace social_network {

enum class ServiceStatus {
    HEALTHY,
    DRAINING,
    UNHEALTHY
};

class HealthChecker {
public:
    static HealthChecker& getInstance() {
        static HealthChecker instance;
        return instance;
    }

    ServiceStatus getStatus() const { return _status.load(); }
    void setStatus(ServiceStatus status) { 
        _status.store(status);
        LOG(info) << "Service status changed to: " << static_cast<int>(status);
    }

private:
    HealthChecker() : _status(ServiceStatus::HEALTHY) {}
    std::atomic<ServiceStatus> _status;
};

class HealthEndpoint {
public:
    explicit HealthEndpoint(int port) {
        LOG(info) << "Starting health endpoint on port " << port;
        _http_endpoint = std::make_shared<Pistache::Http::Endpoint>(
            Pistache::Http::Endpoint::options()
                .threads(1)
                .flags(Pistache::Tcp::Options::InstallSignalHandler)
                .port(port));
        setupRoutes();
    }

    void setupRoutes() {
        auto router = std::make_shared<Pistache::Http::Router>();
        
        Pistache::Rest::Routes::Get(*router, "/health", 
            Pistache::Rest::Routes::bind(&HealthEndpoint::getHealth, this));
        
        _http_endpoint->setHandler(router->handler());
    }

    void start() {
        _http_endpoint->init();
        _http_endpoint->serve();
    }

    void shutdown() {
        _http_endpoint->shutdown();
    }

private:
    void getHealth(const Pistache::Http::Request&, 
                  Pistache::Http::ResponseWriter response) {
        auto status = HealthChecker::getInstance().getStatus();
        
        switch (status) {
            case ServiceStatus::HEALTHY:
                response.send(Pistache::Http::Code::Ok, "healthy");
                break;
            case ServiceStatus::DRAINING:
                response.send(Pistache::Http::Code::ServiceUnavailable, "draining");
                break;
            default:
                response.send(Pistache::Http::Code::ServiceUnavailable, "unhealthy");
        }
    }

    std::shared_ptr<Pistache::Http::Endpoint> _http_endpoint;
};

} // namespace social_network

#endif