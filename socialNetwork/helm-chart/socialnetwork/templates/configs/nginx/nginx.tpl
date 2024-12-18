{{- define "socialnetwork.templates.nginx.nginx.conf"  }}
# Load the OpenTracing dynamic module.
load_module modules/ngx_http_opentracing_module.so;

# Checklist: Make sure that worker_processes == #cores you gave to
# nginx process
worker_processes  auto;

# error_log  logs/error.log;

# Checklist: Make sure that worker_connections * worker_processes
# is greater than the total connections between the client and Nginx. 
events {
  use epoll;
  worker_connections  1024;
}

env fqdn_suffix;

http {
  # Load a vendor tracer
  opentracing on;
  opentracing_load_tracer /usr/local/lib/libjaegertracing_plugin.so /usr/local/openresty/nginx/jaeger-config.json;

  include       mime.types;
  default_type  application/octet-stream;

  proxy_read_timeout 10s;
  proxy_connect_timeout 5s;
  proxy_send_timeout 10s;
  reset_timedout_connection on;
  lingering_close off;
  
  log_format main '$remote_addr - $remote_user [$time_local] "$request"'
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent" "$http_x_forwarded_for"';
  # access_log  logs/access.log  main;

  log_format detailed escape=json '{'
    '"time_local":"$time_local",'
    '"remote_addr":"$remote_addr",'
    '"request":"$request",'
    '"status": "$status",'
    '"request_time":"$request_time",'
    '"upstream_connect_time":"$upstream_connect_time",'
    '"upstream_header_time":"$upstream_header_time",'
    '"upstream_response_time":"$upstream_response_time",'
    '"connection":"$connection",'
    '"connection_requests":"$connection_requests"'
  '}';

  access_by_lua_block {
      local f = io.open("/tmp/nginx_status", "r")
      if f then
          local status = f:read("*all")
          f:close()
          if status:match("shutting_down") then
              ngx.header["Connection"] = "close"
              ngx.status = 503
              ngx.header["Retry-After"] = "5"
              ngx.say('{"error": "Server is shutting down"}')
              return ngx.exit(503)
          end
      end
  }

  access_log /usr/local/openresty/nginx/logs/access.log detailed buffer=32k flush=1s;

  sendfile        on;
  tcp_nopush      on;
  tcp_nodelay     on;

  # Checklist: Make sure the keepalive_timeout is greater than
  # the duration of your experiment and keepalive_requests
  # is greater than the total number of requests sent from
  # the workload generator
  keepalive_timeout  120s;
  keepalive_requests 100000;

  # Docker default hostname resolver. Set valid timeout to prevent unlimited
  # ttl for resolver caching.
  # resolver 127.0.0.11 valid=10s ipv6=off;
  resolver {{ .Values.global.nginx.resolverName }} valid=10s ipv6=off;

  lua_package_path '/usr/local/openresty/nginx/lua-scripts/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;;';

  lua_shared_dict config 32k;
  lua_shared_dict healthcheck 32k;
  lua_shared_dict shutdown_timing 1m;

  init_by_lua_block {
    local bridge_tracer = require "opentracing_bridge_tracer"
    local GenericObjectPool = require "GenericObjectPool"
    local ngx = ngx
    local jwt = require "resty.jwt"
    local cjson = require 'cjson'

    local social_network_UserTimelineService = require 'social_network_UserTimelineService'
    local UserTimelineServiceClient = social_network_UserTimelineService.social_network_UserTimelineService
    local social_network_SocialGraphService = require 'social_network_SocialGraphService'
    local SocialGraphServiceClient = social_network_SocialGraphService.SocialGraphServiceClient
    local social_network_ComposePostService = require 'social_network_ComposePostService'
    local ComposePostServiceClient = social_network_ComposePostService.ComposePostServiceClient
    local social_network_UserService = require 'social_network_UserService'
    local UserServiceClient = social_network_UserService.UserServiceClient


    local config = ngx.shared.config;
    config:set("secret", "secret")
    config:set("cookie_ttl", 3600 * 24)
    config:set("ssl", false)
    config:set("initialized", true)

    local healthcheck = ngx.shared.healthcheck
    healthcheck:set("status", "starting")
  }

  server {
    listen       8080 reuseport;
    server_name  localhost;

    location /nginx-health {
      access_log off;
      default_type application/json;
      content_by_lua '
        local cjson = require "cjson"
        local healthcheck = ngx.shared.healthcheck
        local config = ngx.shared.config
        local timing = ngx.shared.shutdown_timing
        
        -- Check shutdown status first
        local f = io.open("/tmp/nginx_status", "r")
        if f then
          local status = f:read("*all")
          f:close()
          if status:match("shutting_down") then
            -- Start refusing new connections
            ngx.header["Connection"] = "close"
            -- Return 503 with retry-after header
            ngx.header["Retry-After"] = "5"
            ngx.status = 503
            ngx.say(cjson.encode({
                status = "shutting_down",
                ready = false,
                message = "Pod is shutting down",
                shutdown = {
                    in_progress = ngx.worker.exiting(),
                    duration = shutdown_start and (ngx.now() - shutdown_start) or 0,
                    active_connections = ngx.var.connections_active
                }
            }))
            return
          end
        end

        -- Record shutdown timing if we get the signal
        if ngx.worker.exiting() then
            timing:set("shutdown_start", ngx.now())
        end
        
        -- Check initialization
        if not config:get("initialized") then
          ngx.status = 503
          ngx.say(cjson.encode({
            status = "error",
            message = "Core initialization incomplete",
            ready = false,
            shutdown = {
                in_progress = ngx.worker.exiting(),
                duration = shutdown_start and (ngx.now() - shutdown_start) or 0,
                active_connections = ngx.var.connections_active
            }
          }))
          return
        end
        
        -- Check modules
        local function check_module(module_name)
          local success, module = pcall(require, module_name)
          return success
        end
        
        local required_modules = {
          "social_network_UserTimelineService",
          "social_network_SocialGraphService",
          "social_network_ComposePostService",
          "social_network_UserService"
        }
        
        local missing_modules = {}
        for _, module_name in ipairs(required_modules) do
          if not check_module(module_name) then
            table.insert(missing_modules, module_name)
          end
        end
        
        if #missing_modules > 0 then
          ngx.status = 503
          ngx.say(cjson.encode({
            status = "error",
            message = "Missing required modules",
            missing_modules = missing_modules,
            ready = false,
            shutdown = {
                in_progress = ngx.worker.exiting(),
                duration = shutdown_start and (ngx.now() - shutdown_start) or 0,
                active_connections = ngx.var.connections_active
            }
          }))
          return
        end
        
        -- Everything is healthy
        healthcheck:set("status", "ready")
        local shutdown_start = timing:get("shutdown_start")
        ngx.say(cjson.encode({
          status = "healthy",
          initialized = true,
          modules_loaded = true,
          ready = true,
          timestamp = ngx.time(),
          shutdown = {
              in_progress = ngx.worker.exiting(),
              duration = shutdown_start and (ngx.now() - shutdown_start) or 0,
              active_connections = ngx.var.connections_active
          }
        }))
      ';
    }

    # access_log  off;
    # error_log off;

    lua_need_request_body on;

    # Used when SSL enabled
    lua_ssl_trusted_certificate /keys/CA.pem;
    lua_ssl_ciphers ALL:!ADH:!LOW:!EXP:!MD5:@STRENGTH;

    # Checklist: Make sure that the location here is consistent
    # with the location you specified in wrk2.
    location /api/user/register {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/user/register"
          client.RegisterUser();
      ';
    }

    location /api/user/follow {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/user/follow"
          client.Follow();
      ';
    }

    location /api/user/unfollow {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/user/unfollow"
          client.Unfollow();
      ';
    }

    location /api/user/login {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/user/login"
          client.Login();
      ';
    }

    location /api/post/compose {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/post/compose"
          client.ComposePost();
      ';
    }

    location /api/user-timeline/read {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/user-timeline/read"
          client.ReadUserTimeline();
      ';
    }

    location /api/home-timeline/read {
            if ($request_method = 'OPTIONS') {
              add_header 'Access-Control-Allow-Origin' '*';
              add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
              add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
              add_header 'Access-Control-Max-Age' 1728000;
              add_header 'Content-Type' 'text/plain; charset=utf-8';
              add_header 'Content-Length' 0;
              return 204;
            }
            if ($request_method = 'POST') {
              add_header 'Access-Control-Allow-Origin' '*';
              add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
              add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
              add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
            }
            if ($request_method = 'GET') {
              add_header 'Access-Control-Allow-Origin' '*';
              add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
              add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
              add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
            }
      content_by_lua '
          local client = require "api/home-timeline/read"
          client.ReadHomeTimeline();
      ';
    }

    # # get userinfo lua
    # location /api/user/user_info {
    #       if ($request_method = 'OPTIONS') {
    #         add_header 'Access-Control-Allow-Origin' '*';
    #         add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
    #         add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    #         add_header 'Access-Control-Max-Age' 1728000;
    #         add_header 'Content-Type' 'text/plain; charset=utf-8';
    #         add_header 'Content-Length' 0;
    #         return 204;
    #       }
    #       if ($request_method = 'POST') {
    #         add_header 'Access-Control-Allow-Origin' '*';
    #         add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
    #         add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    #         add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
    #       }
    #       if ($request_method = 'GET') {
    #         add_header 'Access-Control-Allow-Origin' '*';
    #         add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
    #         add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    #         add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
    #       }
    #   content_by_lua '
    #       local client = require "api/user/user_info"
    #       client.UserInfo();
    #   ';
    # }
    # get follower lua
    location /api/user/get_follower {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/user/get_follower"
          client.GetFollower();
      ';
    }

    # get followee lua
    location /api/user/get_followee {
          if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
          }
          if ($request_method = 'POST') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
          if ($request_method = 'GET') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
          }
      content_by_lua '
          local client = require "api/user/get_followee"
          client.GetFollowee();
      ';
    }
    location / {
      if ($request_method = 'OPTIONS') {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        add_header 'Access-Control-Max-Age' 1728000;
        add_header 'Content-Type' 'text/plain; charset=utf-8';
        add_header 'Content-Length' 0;
        return 204;
      }
      if ($request_method = 'POST') {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
      }
      if ($request_method = 'GET') {
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
      }
      root pages;
    }

    location /wrk2-api/home-timeline/read {
      content_by_lua '
          local client = require "wrk2-api/home-timeline/read"
          client.ReadHomeTimeline();
      ';
    }

    location /wrk2-api/user-timeline/read {
      content_by_lua '
          local client = require "wrk2-api/user-timeline/read"
          client.ReadUserTimeline();
      ';
    }

    location /wrk2-api/post/compose {
      content_by_lua '
          local client = require "wrk2-api/post/compose"
          client.ComposePost();
      ';
    }

    location /wrk2-api/user/register {
      content_by_lua '
          local client = require "wrk2-api/user/register"
          client.RegisterUser();
      ';
    }

    location /wrk2-api/user/follow {
      content_by_lua '
          local client = require "wrk2-api/user/follow"
          client.Follow();
      ';
    }

    location /wrk2-api/user/unfollow {
      content_by_lua '
          local client = require "wrk2-api/user/unfollow"
          client.Unfollow();
      ';
    }

  }
}
{{- end }}