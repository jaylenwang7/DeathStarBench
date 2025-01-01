#include "microservice_health.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <string.h>

namespace social_network {

ServiceHealth::ServiceHealth(int port, DbOperationTracker& tracker) 
    : db_tracker(tracker) {
    sock_fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    bind(sock_fd, (struct sockaddr*)&addr, sizeof(addr));
    listen(sock_fd, 10);
}

void ServiceHealth::start() {
    running = true;
    server_thread = std::thread(&ServiceHealth::run, this);
}

void ServiceHealth::stop() {
    running = false;
    close(sock_fd);
    if(server_thread.joinable()) {
        server_thread.join();
    }
}

void ServiceHealth::run() {
    while(running) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client = accept(sock_fd, (struct sockaddr*)&client_addr, &client_len);
        
        if (client < 0) {
            if (running) {  // Only log error if we're still meant to be running
                // Could add error logging here
            }
            continue;
        }

        char buffer[1024] = {0};
        ssize_t bytes_read = read(client, buffer, sizeof(buffer) - 1);
        
        if (bytes_read > 0) {
            std::string response;
            if(strstr(buffer, "POST /prepare-shutdown")) {
                prepare_shutdown();
                response = "HTTP/1.1 200 OK\r\n"
                          "Content-Length: 0\r\n"
                          "Connection: close\r\n\r\n";
            }
            else if(strstr(buffer, "GET /active-db-ops")) {
                std::string json = "{\"count\": " + 
                                 std::to_string(db_tracker.get_count()) + 
                                 "}\n";
                response = "HTTP/1.1 200 OK\r\n"
                          "Content-Type: application/json\r\n"
                          "Content-Length: " + std::to_string(json.length()) + "\r\n"
                          "Connection: close\r\n"
                          "\r\n" + json;
            }
            else {
                response = "HTTP/1.1 404 Not Found\r\n"
                          "Content-Length: 0\r\n"
                          "Connection: close\r\n\r\n";
            }
            
            write(client, response.c_str(), response.length());
        }
        
        close(client);
    }
}

ServiceHealth::~ServiceHealth() {
    stop();
}

}