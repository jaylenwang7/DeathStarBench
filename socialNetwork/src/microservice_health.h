#ifndef MICROSERVICE_HEALTH_H
#define MICROSERVICE_HEALTH_H

#include <atomic>
#include <thread>
#include <string>

namespace social_network {
    // Generic operation counter for any database type
    class DbOperationTracker {
    public:
        void track() { active_ops++; }
        void complete() { active_ops--; }
        int get_count() const { return active_ops; }
        
    private:
        std::atomic<int> active_ops{0};
    };

    class ServiceHealth {
    public:
        ServiceHealth(int port, DbOperationTracker& db_tracker);
        void start();
        void stop();
        bool is_accepting_requests() const { return accepting_requests; }
        void prepare_shutdown() { accepting_requests = false; }
        ~ServiceHealth();
        
    private:
        void run();
        int sock_fd;
        bool running;
        std::thread server_thread;
        std::atomic<bool> accepting_requests{true};
        DbOperationTracker& db_tracker;
    };
}

#endif