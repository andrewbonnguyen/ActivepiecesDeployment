#!/bin/sh
set -eu
case "$(ps -p $$ -o comm= 2>/dev/null || echo sh)" in bash) set -o pipefail;; esac
IFS=$'\n\t'

# =====================================================
# Activepieces Advanced Deployment + Nginx Brotli
# =====================================================
AP_DOMAIN="ap.themis.autos"
AP_USER="activepieces"
DEPLOY_DIR="/opt/activepieces"
NGINX_VERSION="1.26.2"
BUILD_DIR="/usr/local/src/nginx-build"

# Random email
EMAIL_ADMIN="admin_$(tr -dc 'a-z0-9' </dev/urandom | head -c10)@$AP_DOMAIN"

echo "Starting Activepieces Production Deployment"
echo "Admin email : $EMAIL_ADMIN"
echo "Domain      : https://$AP_DOMAIN"
echo "Bắt đầu trong 5s… (Ctrl+C để hủy)"
sleep 5

# ==========================
# 1. System update & tools
# ==========================
sudo apt update -y && sudo apt upgrade -y -o Dpkg::Options::="--force-confold"
sudo apt install -y ca-certificates curl gnupg lsb-release git snapd ufw \
                    fail2ban ipset htop build-essential wget \
                    libpcre3 libpcre3-dev zlib1g-dev libssl-dev

# ==========================
# REMOVE OLD NGINX
# ==========================
sudo systemctl stop nginx 2>/dev/null || true
sudo apt remove -y nginx nginx-core nginx-common || true
sudo apt purge -y nginx nginx-core nginx-common || true
sudo apt autoremove -y

# =======================================================
# Install NGINX 1.26.2 + Brotli — CHẠY 100% TRÊN UBUNTU 24.04
# =======================================================
sudo apt install -y build-essential git curl wget ca-certificates \
    libpcre3 libpcre3-dev zlib1g-dev libssl-dev cmake

sudo rm -rf "$BUILD_DIR"
sudo mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Fix lỗi 404: thêm số phiên bản đầy đủ
wget "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
tar -xzf "nginx-${NGINX_VERSION}.tar.gz"

# Fix lỗi clone: bỏ chữ "clone" thừa
git clone --recurse-submodules -j8 https://github.com/google/ngx_brotli.git

# Build Brotli tĩnh
cd ngx_brotli/deps/brotli
mkdir -p out && cd out
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
make -j$(nproc)

# Build NGINX + chỉ đường Brotli đúng chỗ
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
  --with-ld-opt="-L$BUILD_DIR/ngx_brotli/deps/brotli/out" \
  --with-cc-opt="-I$BUILD_DIR/ngx_brotli/deps/brotli/c/include" \
  --add-module="$BUILD_DIR/ngx_brotli"

sudo make -j$(nproc)
sudo make install

sudo tee /etc/systemd/system/nginx.service > /dev/null <<EOF
[Unit]
Description=NGINX + Brotli
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

# Load conf.d
grep -q "include.*conf.d" /etc/nginx/nginx.conf || \
  sudo sed -i '/http {/a\    include /etc/nginx/conf.d/*.conf;' /etc/nginx/nginx.conf

# ==========================
# Docker install
# ==========================
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

# ==========================
# User + thư mục
# ==========================
sudo useradd -m -s /bin/bash "$AP_USER" 2>/dev/null || true
sudo usermod -aG docker "$AP_USER"
sudo mkdir -p "$DEPLOY_DIR"
sudo chown -R "$AP_USER:$AP_USER" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# ==========================
# Deploy Activepieces
# ==========================
sudo -u "$AP_USER" mkdir -p activepieces
cd activepieces

# <<< SỬA CHÍNH: port 3000 + healthcheck đầy đủ + key sinh trước >>>
JWT_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 16)

sudo -u "$AP_USER" tee docker-compose.yml > /dev/null <<EOF
services:
  activepieces:
    image: ghcr.io/activepieces/activepieces:0.39.7
    container_name: activepieces
    restart: always
    ports:
      - "127.0.0.1:3000:80"                 #3000 (hoặc bất kỳ port nào chưa dùng)
    environment:
      - AP_DB_TYPE=postgres
      - AP_POSTGRES_HOST=postgres
      - AP_POSTGRES_PORT=5432
      - AP_POSTGRES_USERNAME=activepieces
      - AP_POSTGRES_PASSWORD=SuperSecretPass123!
      - AP_POSTGRES_DATABASE=activepieces
      - AP_REDIS_URL=redis://redis:6379
      - AP_JWT_SECRET=$JWT_SECRET
      - AP_ENCRYPTION_KEY=$ENCRYPTION_KEY
      - AP_FRONTEND_URL=https://$AP_DOMAIN
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
      start_interval: 5s

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

docker compose down -v 2>/dev/null || true
docker compose up -d --wait

# ==========================
# SSL Certbot
# ==========================
sudo snap install --classic certbot || true
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
sudo fuser -k 80/tcp 443/tcp || true
sudo systemctl stop nginx
sudo certbot certonly --standalone -d "$AP_DOMAIN" \
     --non-interactive --agree-tos -m "$EMAIL_ADMIN" --keep-until-expiring

# ==========================
# Nginx config – sửa proxy_pass + thêm cache zone
# ==========================
sudo mkdir -p /etc/nginx/conf.d

# Thêm cache zone vào nginx.conf (chỉ thêm 1 lần)
grep -q "proxy_cache_path" /etc/nginx/nginx.conf || \
sudo sed -i '/http {/a\    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=ap_cache:50m max_size=1g inactive=7d use_temp_path=off;' /etc/nginx/nginx.conf

sudo mkdir -p /var/cache/nginx
sudo chown www-data:www-data /var/cache/nginx

sudo tee /etc/nginx/conf.d/activepieces.conf > /dev/null <<EOF
limit_req_zone \$binary_remote_addr zone=activepieces:10m rate=10r/m;
limit_conn_zone \$binary_remote_addr zone=addr:10m;

server {
    listen 80;
    server_name $AP_DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $AP_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$AP_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$AP_DOMAIN/privkey.pem;
    include            /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam       /etc/letsencrypt/ssl-dhparams.pem;

    server_tokens off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:3000;            # port 3000
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }

    # Brotli & Gzip
    brotli on;
    brotli_static on;
    brotli_types text/plain text/css application/json application/javascript;

    gzip on;
    gzip_static on;
}
EOF

sudo nginx -t && sudo systemctl restart nginx

# ==========================
# Systemd service Activepieces
# ==========================
sudo tee /etc/systemd/system/activepieces.service > /dev/null <<EOF
[Unit]
Description=Activepieces
After=network.target docker.service
Requires=docker.service
[Service]
User=$AP_USER
WorkingDirectory=$DEPLOY_DIR/activepieces
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now activepieces.service

echo ""
echo "🎉 ACTIVEPIECES DEPLOYMENT COMPLETED!"
echo "🌐 Visit: https://${AP_DOMAIN}"
echo "📧 Admin email: ${EMAIL_ADMIN}"
