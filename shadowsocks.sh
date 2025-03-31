#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен с правами root" >&2
  exit 1
fi

# Параметры
DOMAIN="test.com"
SSH_ALLOW_IPS=("10.10.10.10" "9.9.9.9")
SHADOWSOCKS_PORT=8388
WEB_ROOT="/var/www/$DOMAIN/html"

# 1. Обновление системы
echo "Обновление системы..."
apt update && apt upgrade -y

# 2. Установка необходимых пакетов
echo "Установка необходимых пакетов..."
apt install -y shadowsocks-libev certbot python3-certbot-nginx nginx ufw

# 3. Настройка UFW
echo "Настройка брандмауэра..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH только с указанных IP
for ip in "${SSH_ALLOW_IPS[@]}"; do
  ufw allow from "$ip" to any port 22 proto tcp
done

# Разрешаем HTTP/HTTPS и порт Shadowsocks
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow "$SHADOWSOCKS_PORT"/tcp
ufw allow "$SHADOWSOCKS_PORT"/udp

# Включаем UFW
ufw --force enable

# 4. Настройка Shadowsocks
echo "Настройка Shadowsocks..."
SHADOWSOCKS_CONFIG="/etc/shadowsocks-libev/config.json"
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

cat > "$SHADOWSOCKS_CONFIG" <<EOL
{
    "server":["::0","0.0.0.0"],
    "server_port":$SHADOWSOCKS_PORT,
    "password":"$PASSWORD",
    "timeout":300,
    "method":"chacha20-ietf-poly1305",
    "fast_open":false,
    "mode":"tcp_and_udp",
    "nameserver":"8.8.8.8"
}
EOL

systemctl enable shadowsocks-libev.service
systemctl restart shadowsocks-libev.service

# 5. Подготовка веб-сервера для Certbot
echo "Подготовка веб-сервера..."
mkdir -p "$WEB_ROOT"
echo "Shadowsocks Server" > "$WEB_ROOT/index.html"
chown -R www-data:www-data "/var/www/$DOMAIN"
chmod -R 755 "/var/www/$DOMAIN"

# 6. Настройка Nginx (временная конфигурация для получения сертификата)
TEMP_NGINX_CONFIG="/etc/nginx/sites-available/$DOMAIN"
cat > "$TEMP_NGINX_CONFIG" <<EOL
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    root $WEB_ROOT;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.well-known/acme-challenge {
        allow all;
    }
}
EOL

ln -sf "$TEMP_NGINX_CONFIG" "/etc/nginx/sites-enabled/"
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

# 7. Проверка доступности домена перед получением сертификата
echo "Проверка доступности домена..."
if ! curl -Is "http://$DOMAIN" | head -n 1 | grep -q 200; then
  echo "Ошибка: Домен $DOMAIN не доступен на порту 80"
  echo "Проверьте:"
  echo "1. DNS записи (должны указывать на этот сервер)"
  echo "2. Брандмауэр (должен разрешать порт 80)"
  exit 1
fi

# 8. Получение SSL сертификата
echo "Получение SSL сертификата..."
if ! certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN"; then
  echo "Не удалось получить сертификат. Пробуем standalone метод..."
  systemctl stop nginx
  if ! certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "admin@$DOMAIN"; then
    echo "Ошибка получения сертификата. Проверьте логи:"
    echo "/var/log/letsencrypt/letsencrypt.log"
    systemctl start nginx
    exit 1
  fi
  systemctl start nginx
fi

# 9. Финальная настройка Nginx с SSL
cat > "$TEMP_NGINX_CONFIG" <<EOL
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    root $WEB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 443 ssl http2;
    server_name www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    return 301 https://$DOMAIN\$request_uri;
}
EOL

# 10. Проверка и перезапуск Nginx
nginx -t && systemctl restart nginx || { echo "Ошибка конфигурации Nginx"; exit 1; }

# 11. Настройка автоматического обновления сертификатов
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -

# 12. Вывод информации
echo -e "\n\nНастройка успешно завершена!"
echo "========================================"
echo "Данные для подключения к Shadowsocks:"
echo "Адрес сервера: $DOMAIN"
echo "Порт: $SHADOWSOCKS_PORT"
echo "Пароль: $PASSWORD"
echo "Метод шифрования: chacha20-ietf-poly1305"
echo "========================================"
echo -e "\nНе забудьте добавить запись DNS для $DOMAIN если ещё не сделали этого!"
