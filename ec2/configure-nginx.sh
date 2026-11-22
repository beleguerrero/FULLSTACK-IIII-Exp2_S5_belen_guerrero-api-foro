
#!/usr/bin/env bash
set -Eeuo pipefail

NGINX_LISTEN_PORT="${NGINX_LISTEN_PORT:-80}"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_CONF="${NGINX_CONF_DIR}/api-proxy.conf"
BACKUP_DIR="/var/backups/nginx"
TEMP_CONF=""

log() {
    printf 'configure-nginx: %s\n' "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_CONF:-}" && -f "$TEMP_CONF" ]]; then
        rm -f "$TEMP_CONF"
    fi
}

trap cleanup EXIT

[[ "$EUID" -eq 0 ]] || fail "Este script debe ejecutarse como root."

command -v nginx >/dev/null 2>&1 || fail "Nginx no está instalado."
systemctl is-active --quiet nginx || fail "Nginx no está activo."

[[ "$NGINX_LISTEN_PORT" =~ ^[0-9]{1,5}$ ]] \
    || fail "Puerto inválido: $NGINX_LISTEN_PORT"

(( NGINX_LISTEN_PORT >= 1 && NGINX_LISTEN_PORT <= 65535 )) \
    || fail "Puerto fuera de rango."

mkdir -p "$NGINX_CONF_DIR" "$BACKUP_DIR"

BACKUP_FILE="${BACKUP_DIR}/api-proxy.conf.$(date -u +%Y%m%d-%H%M%S).$$.bak"

if [[ -f "$NGINX_CONF" ]]; then
    cp -p "$NGINX_CONF" "$BACKUP_FILE"
    log "Respaldo creado: $BACKUP_FILE"
fi

TEMP_CONF="$(mktemp "${NGINX_CONF_DIR}/.api-proxy.conf.XXXXXX")"

cat > "$TEMP_CONF" <<EOF
server {
    listen ${NGINX_LISTEN_PORT};
    server_name _;

    client_max_body_size 10m;

    location = /api/mi-foro/usuarios {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/mi-foro/ {
        proxy_pass http://127.0.0.1:8082;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        return 404;
    }
}
EOF

chmod 644 "$TEMP_CONF"

if ! nginx -t; then
    log "La configuración nueva no es válida."

    if [[ -f "$BACKUP_FILE" ]]; then
        cp -p "$BACKUP_FILE" "$NGINX_CONF"
    else
        rm -f "$NGINX_CONF"
    fi

    nginx -t || true
    fail "Se restauró la configuración anterior."
fi

mv "$TEMP_CONF" "$NGINX_CONF"
TEMP_CONF=""

if ! nginx -t; then
    log "Falló la validación después de instalar la configuración."

    if [[ -f "$BACKUP_FILE" ]]; then
        cp -p "$BACKUP_FILE" "$NGINX_CONF"
    else
        rm -f "$NGINX_CONF"
    fi

    systemctl reload nginx || true
    fail "Se restauró la configuración anterior."
fi

if ! systemctl reload nginx; then
    log "Falló la recarga de Nginx."

    if [[ -f "$BACKUP_FILE" ]]; then
        cp -p "$BACKUP_FILE" "$NGINX_CONF"
    else
        rm -f "$NGINX_CONF"
    fi

    nginx -t && systemctl reload nginx || true
    fail "Se restauró la configuración anterior."
fi

log "Nginx configurado y recargado correctamente."
log "Usuarios API: 127.0.0.1:8081"
log "Foro API: 127.0.0.1:8082"
