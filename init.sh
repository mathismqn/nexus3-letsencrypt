#!/bin/bash

set -e

if ! docker compose version &> /dev/null; then
    echo "Error: docker compose is not installed." >&2
    exit 1
fi

if ! grep -q "DOMAIN_NAME" ./nginx/default.conf; then
    read -p "A configuration already exists. Would you like to overwrite it? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        rm -rf ./nginx/default.conf
        cat > ./nginx/default.conf <<EOF
server {
    listen 80;
    server_name DOMAIN_NAME www.DOMAIN_NAME;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    #location / {
        #return 301 https://DOMAIN_NAME\$request_uri;
    #}

}

#server {
    #listen 443 ssl;
    #server_name DOMAIN_NAME www.DOMAIN_NAME;

    #ssl_certificate /etc/nginx/ssl/live/DOMAIN_NAME/fullchain.pem;
    #ssl_certificate_key /etc/nginx/ssl/live/DOMAIN_NAME/privkey.pem;
    
    #location / {
        #proxy_pass http://nexus:8081/;
        #proxy_set_header Host \$host;
        #proxy_set_header X-Real-IP \$remote_addr;
        #proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        #proxy_set_header X-Forwarded-Proto \$scheme;
    #}
#}
EOF
        sudo rm -rf ./certbot/*
        echo "Configuration overwritten."
        echo
    else
        exit 0
    fi
fi

read -p "Which domain name would you like to obtain a certificate for? " domain_name
if ! [[ "$domain_name" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "Error: invalid domain name." >&2
    exit 1
fi

read -p "Which email address would you like to link your certificate to? " email_address
if ! [[ "$email_address" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "Error: invalid email address." >&2
    exit 1
fi

read -p "Would you like to generate a certificate for testing purposes? [y/N] " staging

sed -i "s/DOMAIN_NAME/$domain_name/g" ./nginx/default.conf
echo

echo "### Pulling images..."
docker pull nginx:1.25.3-alpine3.18
docker pull certbot/certbot:v2.7.3
docker pull sonatype/nexus3:3.61.0
echo

echo "### Starting nginx..."
docker compose down &> /dev/null
sleep 3
docker compose up -d nginx &> /dev/null
while ! curl -I localhost &> /dev/null; do
    sleep 1
done
echo "Nginx successfully started."
echo

echo "### Requesting a certificate from Let's Encrypt..."
if [[ "$staging" =~ ^[Yy]$ ]]; then staging_arg="--staging"; fi
docker compose run --rm  certbot certonly --webroot --webroot-path /var/www/certbot/ -d $domain_name -d www.$domain_name -m $email_address --agree-tos --no-eff-email --force-renewal $staging_arg
echo

sed -i 's/#//g' ./nginx/default.conf

echo "### Starting nexus..."
docker compose restart nginx &> /dev/null
docker compose up -d nexus &> /dev/null
while ! curl -I --insecure https://$domain_name 2> /dev/null | grep -q "HTTP/1.1 200 OK"; do
    sleep 1
done

nexus_pass=$(docker compose exec nexus cat /nexus-data/admin.password)

echo "Nexus successfully started."
echo "Username: admin"
echo "Password: $nexus_pass"
