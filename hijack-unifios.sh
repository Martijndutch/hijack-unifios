#!/bin/bash

# --- DEFAULT CONFIGURATION ---
DEFAULT_DOMAIN="yourserver.nl"
DEFAULT_EMAIL="youremail@gmail.com"

# --- PROMPT USER (WITH DEFAULTS) ---
read -p "Enter domain name [$DEFAULT_DOMAIN]: " DOMAIN
DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}

read -p "Enter email address [$DEFAULT_EMAIL]: " EMAIL
EMAIL=${EMAIL:-$DEFAULT_EMAIL}

# Port Configuration
GUEST_HIJACK_PORT="8444"       # Public Port
GUEST_NGINX_PORT="8445"        # Nginx Trap

ADMIN_HIJACK_PORT="11443"      # Public Port
ADMIN_NGINX_PORT="11442"       # Nginx Trap

echo "---------------------------------------------"
echo "Using domain : $DOMAIN"
echo "Using email  : $EMAIL"
echo "---------------------------------------------"

# --- 1. PRE-FLIGHT CHECKS & AUTO-DETECTION ---
echo "Starting UniFi OS SSL Setup..."

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    echo "ERROR: Could not detect network interface."
    exit 1
fi
echo "Detected interface: $INTERFACE"

# --- 2. INSTALL SYSTEM DEPENDENCIES ---
echo "Installing dependencies..."
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx iptables-persistent openssl

# --- 3. CERTIFICATE MANAGEMENT ---
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo "Requesting Let's Encrypt certificate..."
    sudo systemctl stop nginx
    sudo certbot certonly \
        --standalone \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        -m "$EMAIL"
    sudo systemctl start nginx
else
    echo "Existing certificate found for $DOMAIN. Skipping request."
fi

# --- 4. CONFIGURE NGINX ---
echo "Configuring Nginx reverse proxy..."

cat <<EOF | sudo tee /etc/nginx/sites-available/unifi-portal
# =========================
# Guest Portal Hijack Trap
# =========================
server {
    listen $GUEST_NGINX_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass https://127.0.0.1:8444;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_ssl_verify off;
    }
}

# =========================
# Admin Console Hijack Trap
# =========================
server {
    listen $ADMIN_NGINX_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 1024m;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;

    location / {
        proxy_pass https://127.0.0.1:11443;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_ssl_verify off;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/unifi-portal /etc/nginx/sites-enabled/unifi-portal
sudo rm -f /etc/nginx/sites-enabled/default

# --- 5. RESTART NGINX ---
if sudo nginx -t; then
    sudo systemctl restart nginx
    echo "Nginx restarted successfully."
else
    echo "ERROR: Nginx configuration test failed."
    exit 1
fi

# --- 6. IPTABLES HIJACK RULES ---
echo "Applying iptables redirect rules..."

sudo iptables -t nat -F PREROUTING

sudo iptables -t nat -A PREROUTING -i "$INTERFACE" -p tcp --dport $GUEST_HIJACK_PORT \
    -j REDIRECT --to-port $GUEST_NGINX_PORT

sudo iptables -t nat -A PREROUTING -i "$INTERFACE" -p tcp --dport $ADMIN_HIJACK_PORT \
    -j REDIRECT --to-port $ADMIN_NGINX_PORT

echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | sudo debconf-set-selections
sudo netfilter-persistent save

# --- 7. CERTBOT AUTO-RELOAD ---
echo "Adding certbot renewal hook..."
sudo mkdir -p /etc/letsencrypt/renewal-hooks/post/

cat <<EOF | sudo tee /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh
#!/bin/bash
systemctl reload nginx
EOF

sudo chmod +x /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh

echo "-------------------------------------------------------"
echo "SETUP SUCCESSFUL"
echo "Domain        : $DOMAIN"
echo "Admin Console : https://$DOMAIN:11443"
echo "Guest Portal  : https://$DOMAIN:8444"
echo "-------------------------------------------------------"
