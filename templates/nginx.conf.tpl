worker_processes auto;
pid /run/nginx.pid;

# Load distro-managed dynamic modules (for stream module on package installs).
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
}

stream {
    log_format stream_log '$remote_addr [$time_local] '
                          '$ssl_preread_server_name -> $upstream_addr '
                          'status=$status bytes_in=$bytes_received bytes_out=$bytes_sent '
                          'session=$session_time';
    access_log /var/log/nginx/stream-access.log stream_log;
    error_log /var/log/nginx/stream-error.log warn;

    map $ssl_preread_server_name $backend_upstream {
__MAP_ENTRIES__
        default         __DEFAULT_BACKEND__;
    }

    server {
        listen __NGINX_PUBLIC_LISTEN__ reuseport;
        proxy_connect_timeout 3s;
        proxy_timeout 300s;
        proxy_pass $backend_upstream;
        ssl_preread on;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;

__TROJAN_FALLBACK_SERVER_BLOCK__

    server {
        listen __STATIC_LISTEN__ ssl;
        server_name __DEFAULT_STATIC_HTML_DOMAIN__;

        ssl_certificate __STATIC_CERT_FILE__;
        ssl_certificate_key __STATIC_KEY_FILE__;
        ssl_session_cache shared:SSL:20m;
        ssl_session_timeout 10m;
        ssl_protocols TLSv1.2 TLSv1.3;

        root __STATIC_WEB_ROOT__;
        index index.html;

        location / {
            try_files $uri $uri/ /index.html;
        }
    }
}
