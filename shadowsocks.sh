#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен с правами root" >&2
  exit 1
fi

# Обновление системы
echo "Обновление системы..."
apt update && apt upgrade -y

# Установка необходимых пакетов
echo "Установка необходимых пакетов..."
apt install -y shadowsocks-libev certbot python3-certbot-nginx nginx ufw

# Настройка UFW
echo "Настройка брандмауэра..."
ufw reset
ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH только с указанных IP
ufw allow from 10.10.10.10 to any port 22 proto tcp
ufw allow from 9.9.9.9 to any port 22 proto tcp

# Разрешаем HTTP и HTTPS для certbot
ufw allow 80/tcp
ufw allow 443/tcp

# Включаем UFW
ufw enable

# Настройка Shadowsocks
echo "Настройка Shadowsocks..."
SHADOWSOCKS_CONFIG="/etc/shadowsocks-libev/config.json"
PORT=8388
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

cat > $SHADOWSOCKS_CONFIG <<EOL
{
    "server":["::0","0.0.0.0"],
    "server_port":$PORT,
    "password":"$PASSWORD",
    "timeout":300,
    "method":"chacha20-ietf-poly1305",
    "fast_open":false,
    "mode":"tcp_and_udp",
    "nameserver":"8.8.8.8"
}
EOL

# Включение и запуск Shadowsocks
systemctl enable shadowsocks-libev.service
systemctl restart shadowsocks-libev.service

# Настройка Nginx для домена
echo "Настройка Nginx..."
DOMAIN="test.com"
NGINX_CONFIG="/etc/nginx/sites-available/$DOMAIN"

cat > $NGINX_CONFIG <<EOL
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOL

ln -s $NGINX_CONFIG /etc/nginx/sites-enabled/
rm /etc/nginx/sites-enabled/default

# Получение SSL сертификата
echo "Получение SSL сертификата..."
certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN

# Перезапуск Nginx
systemctl restart nginx

# Разрешаем порт Shadowsocks в UFW
ufw allow $PORT/tcp
ufw allow $PORT/udp

# Вывод информации
echo "Настройка завершена!"
echo "Данные для подключения к Shadowsocks:"
echo "Адрес сервера: $DOMAIN"
echo "Порт: $PORT"
echo "Пароль: $PASSWORD"
echo "Метод шифрования: chacha20-ietf-poly1305"
