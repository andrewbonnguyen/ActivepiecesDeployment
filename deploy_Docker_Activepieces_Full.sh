#!/bin/sh
set -eu
case "$(ps -p $$ -o comm= 2>/dev/null || echo sh)" in bash) set -o pipefail;; esac
IFS=$'\n\t'

# =====================================================
# Activepieces Advanced Deployment + Nginx Brotli (FIXED)
# =====================================================

AP_DOMAIN="ap.themis.autos"
AP_USER="activepieces"
DEPLOY_DIR="/opt/activepieces"
NODE_VERSION="20"
NGINX_VERSION="1.26.2"
BUILD_DIR="/usr/local/src/nginx-build"

# Create random safe email
EMAIL_ADMIN="admin_$(tr -dc 'a-z0-9' </dev/urandom | head -c10)${AP_DOMAIN:+@$AP_DOMAIN}"
EMAIL_ADMIN="${EMAIL_ADMIN#@}"

echo "🚀 Starting Activepieces Production Deployment"
echo "📧 Admin email: $EMAIL_ADMIN"
echo "🌐 Domain: https://$AP_DOMAIN"
echo "Bắt đầu trong 5s… (Ctrl+C để hủy)"
sleep 5


# ==========================
# 1. System update & tools
# ==========================
sudo apt update -y && sudo apt upgrade -y -o Dpkg::Options::="--force-confold"
sudo apt install -y ca-certificates curl gnupg lsb-release git snapd ufw \
                    fail2ban ipset htop build-essential wget \
                    libpcre3 libpcre3-dev zlib1g-dev libssl-dev \
                    -o Dpkg::Options::="--force-confold"

# ==========================
# REMOVE OLD NGINX
# ==========================
sudo systemctl stop nginx 2>/dev/null || true
sudo apt remove -y nginx nginx-core nginx-common || true
sudo apt purge -y nginx nginx-core nginx-common || true

# =======================================================
# Install NGINX + Brotli — FIXED
# =======================================================

sudo apt install -y build-essential git curl wget unzip ca-certificates \
    libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev cmake -o Dpkg::Options::="--force-confold"

sudo rm -rf "$BUILD_DIR"
sudo mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

wget "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
tar -xzf "nginx-${NGINX_VERSION}.tar.gz"

git clone https://github.com/google/ngx_brotli.git
cd ngx_brotli
git submodule update --init --recursive

cd deps/brotli
mkdir -p out && cd out
cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON ..
make -j"$(nproc)"

cd "$BUILD_DIR/nginx-${NGINX_VERSION}"

sudo ./configure \
  --prefix=/etc/nginx \
  --sbin-path=/usr/sbin/nginx \
  --modules-path=/usr/lib/nginx/modules \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --http-log-path=/var/log/nginx/access.log \
  --pid-path=/var/run/nginx.pid \
  --lock-path=/var/run/nginx.lock \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_gzip_static_module \
  --with-threads \
  --add-module="$BUILD_DIR/ngx_brotli"

sudo make -j"$(nproc)"
sudo make install

sudo tee /etc/systemd/system/nginx.service > /dev/null <<EOF
[Unit]
Description=NGINX web server (custom build + Brotli)
After=network.target

[Service]
ExecStart=/usr/sbin/nginx -g 'daemon off;'
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/usr/sbin/nginx -s quit
PIDFile=/var/run/nginx.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nginx

sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-available/default

# Ensure conf.d loaded
grep -q "include /etc/nginx/conf.d" /etc/nginx/nginx.conf || \
sudo sed -i '/http {/a \    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf

sudo nginx -t

# ==========================
# Docker install
# ==========================
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

sudo usermod -aG docker "${SUDO_USER:-$USER}"

# ==========================
# Create Activepieces user & directory
# ==========================
sudo useradd -m -s /bin/bash "$AP_USER" || true
sudo usermod -aG docker "$AP_USER" || true

sudo mkdir -p "$DEPLOY_DIR"
sudo chown -R "$AP_USER:$AP_USER" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# ==========================
# Clone & Deploy Activepieces
# ==========================
if [ ! -d "activepieces" ]; then
    sudo -u "$AP_USER" git clone https://github.com/Activepieces/activepieces.git
fi

cd activepieces

# Dùng file docker-compose đã được fix healthcheck + localhost only
sudo -u "$AP_USER" tee docker-compose.yml > /dev/null <<'EOF'
services:
  activepieces:
    image: ghcr.io/activepieces/activepieces:0.39.7
    container_name: activepieces
    restart: always
    ports:
      - "127.0.0.1:8080:80"
    environment:
      - AP_DB_TYPE=postgres
      - AP_POSTGRES_HOST=postgres
      - AP_POSTGRES_PORT=5432
      - AP_POSTGRES_USERNAME=activepieces
      - AP_POSTGRES_PASSWORD=SuperSecretPass123!
      - AP_POSTGRES_DATABASE=activepieces
      - AP_REDIS_URL=redis://redis:6379
      - AP_JWT_SECRET=$(openssl rand -hex 32)
      - AP_ENCRYPTION_KEY=$(openssl rand -hex 16)
      - AP_FRONTEND_URL=https://ap.themis.autos
      - AP_TELEMETRY_ENABLED=false
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: activepieces
      POSTGRES_PASSWORD: SuperSecretPass123!
      POSTGRES_DB: activepieces
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U activepieces"]
      interval: 10s
      timeout: 30s
      retries: 10
      start_period: 40s

  redis:
    image: redis:7-alpine
    restart: always
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

volumes:
  postgres_data:
  redis_data:
EOF

docker compose up -d --wait || exit 1

# ==========================
# SSL via Certbot
# ==========================
sudo snap install --classic certbot || true
sudo ln -fs /snap/bin/certbot /usr/bin/certbot

# Ensure port 80 free
sudo fuser -k 80/tcp || true
sudo fuser -k 443/tcp || true

sudo certbot certonly --standalone -d "$AP_DOMAIN" \
     --non-interactive --agree-tos -m "$EMAIL_ADMIN" || true

sudo systemctl restart nginx

# ==========================
# Nginx Reverse Proxy config — FIXED
# ==========================
sudo mkdir -p /etc/nginx/conf.d
sudo tee /etc/nginx/conf.d/activepieces.conf >/dev/null <<EOF
limit_req_zone \$binary_remote_addr zone=activepieces:10m rate=10r/m;
limit_conn_zone \$binary_remote_addr zone=addr:10m;

server {
    listen 443 ssl;
	http2 on;
    server_name ${AP_DOMAIN};

    limit_req zone=activepieces burst=20 nodelay;
    limit_conn addr 20;

    server_tokens off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;

    location ~* \.env { deny all; }
    location ~* /\.git { deny all; }
    location ~* \.(ini|log|sql|sh|bak)$ { deny all; }

    location ~* ^/assets/.*\.(js|css|png|jpg|jpeg|gif|svg|webp|ico|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable";
        proxy_pass http://127.0.0.1:8080;
        proxy_cache_bypass \$http_upgrade;
        proxy_cache activepieces_cache;
        proxy_cache_valid 200 30d;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
    	proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 120s;
        proxy_send_timeout 60s;
    }

    client_max_body_size 50M;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    brotli on;
    brotli_comp_level 6;
    brotli_static on;
    brotli_types text/plain text/css application/json application/javascript text_xml application_xml;

    ssl_certificate /etc/letsencrypt/live/${AP_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${AP_DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
}

server {
    listen 80;
    server_name ${AP_DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

# Fix missing cache zone
grep -q "proxy_cache_path" /etc/nginx/nginx.conf || \
sudo sed -i '/http {/a \
    proxy_cache_path /var/cache/nginx/activepieces levels=1:2 keys_zone=activepieces_cache:50m inactive=7d max_size=1g;\
' /etc/nginx/nginx.conf


sudo mkdir -p /var/cache/nginx/activepieces
sudo chown -R www-data:www-data /var/cache/nginx

sudo nginx -t && sudo systemctl reload nginx

# ==========================
# Activepieces Systemd
# ==========================
sudo tee /etc/systemd/system/activepieces.service >/dev/null <<EOF
[Unit]
Description=Activepieces
After=docker.service
Requires=docker.service

[Service]
User=${AP_USER}
WorkingDirectory=${DEPLOY_DIR}/activepieces
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now activepieces.service

echo "🎉 ACTIVEPIECES DEPLOYMENT COMPLETED!"
echo "🌐 Visit: https://${AP_DOMAIN}"
echo "📧 Admin email: ${EMAIL_ADMIN}"
