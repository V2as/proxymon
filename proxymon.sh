#!/bin/bash
set -e

PROXYMON_DIR="/opt/proxymon"
CERTS_DIR="$PROXYMON_DIR/certs"
ENV_FILE="$PROXYMON_DIR/.env"
COMPOSE_FILE="$PROXYMON_DIR/docker-compose.yml"
DOCKER_MIRROR="https://mirror.gcr.io"
IMAGE="v2as/proxymon:latest"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Docker checks ────────────────────────────────────────────────

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_info "Docker not found. Installing..."
        curl -fsSL https://get.docker.com | sh
        systemctl start docker
        systemctl enable docker
    fi

    if ! docker compose version &>/dev/null; then
        log_info "Docker Compose plugin not found. Installing..."
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin 2>/dev/null || {
            log_warn "apt install failed, reinstalling Docker..."
            curl -fsSL https://get.docker.com | sh
        }
    fi
}

ensure_docker_mirror() {
    local daemon_json="/etc/docker/daemon.json"

    if [ -f "$daemon_json" ] && grep -q "$DOCKER_MIRROR" "$daemon_json" 2>/dev/null; then
        return 0
    fi

    log_info "Configuring Docker registry mirror..."
    mkdir -p /etc/docker
    cat > "$daemon_json" <<EOF
{
    "registry-mirrors": ["$DOCKER_MIRROR"]
}
EOF
    systemctl restart docker
    log_info "Docker mirror configured and daemon restarted."
}

# ── Helpers ───────────────────────────────────────────────────────

create_env() {
    local token="$1"
    mkdir -p "$PROXYMON_DIR"

    if [ -n "$token" ]; then
        echo "TOKEN=$token" > "$ENV_FILE"
        log_info ".env created with TOKEN."
    else
        touch "$ENV_FILE"
        log_warn ".env created without TOKEN — API will be unprotected!"
    fi
}

create_compose() {
    mkdir -p "$CERTS_DIR"
    cat > "$COMPOSE_FILE" <<'EOF'
services:
  proxymon:
    image: v2as/proxymon:latest
    container_name: proxymon
    restart: always
    network_mode: host
    pid: host
    privileged: true
    env_file:
      - .env
    volumes:
      - ./certs:/opt/proxymon/certs:ro
EOF
    log_info "docker-compose.yml created."
}

set_env_var() {
    local key="$1" value="$2"
    if [ ! -f "$ENV_FILE" ]; then
        echo "${key}=${value}" > "$ENV_FILE"
    elif grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# ── Commands ──────────────────────────────────────────────────────

cmd_install() {
    local token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token=*) token="${1#*=}"; shift ;;
            --token)   token="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    log_info "Installing ProxyMon..."

    check_docker
    ensure_docker_mirror

    create_env "$token"
    create_compose

    cd "$PROXYMON_DIR"
    docker compose pull
    docker compose up -d

    log_info "ProxyMon installed and running."
    docker ps --filter name=proxymon --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_migrate() {
    local token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token=*) token="${1#*=}"; shift ;;
            --token)   token="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    log_info "Migrating from ansible-deployed proxyapi to ProxyMon Docker image..."

    check_docker
    ensure_docker_mirror

    # Stop old proxyapi container
    if docker ps -a --format '{{.Names}}' | grep -q '^proxyapi$'; then
        log_info "Stopping old proxyapi container..."
        if [ -f /opt/proxyapi/docker-compose.yml ]; then
            cd /opt/proxyapi && docker compose down --remove-orphans 2>/dev/null || true
        else
            docker stop proxyapi 2>/dev/null || true
            docker rm proxyapi 2>/dev/null || true
        fi
    fi

    # Remove old proxyapi images to free space
    docker image prune -af --filter "label!=proxymon" 2>/dev/null || true

    create_env "$token"
    create_compose

    # Migrate certificates from old proxyapi
    local old_certs="/opt/proxyapi/certs"
    if [ -d "$old_certs" ] && [ "$(ls -A "$old_certs" 2>/dev/null)" ]; then
        log_info "Migrating certificates from $old_certs..."
        cp -a "$old_certs"/. "$CERTS_DIR"/

        local cert_file="" key_file=""
        for f in "$CERTS_DIR"/*; do
            [ -f "$f" ] || continue
            if openssl x509 -noout -in "$f" 2>/dev/null; then
                cert_file="$f"
            elif openssl pkey -noout -in "$f" 2>/dev/null; then
                key_file="$f"
            fi
        done

        if [ -n "$cert_file" ] && [ -n "$key_file" ]; then
            cp "$cert_file" "$CERTS_DIR/cert.pem"
            cp "$key_file"  "$CERTS_DIR/key.pem"
            chmod 600 "$CERTS_DIR/cert.pem" "$CERTS_DIR/key.pem"
            set_env_var "TLS_CERT" "/opt/proxymon/certs/cert.pem"
            set_env_var "TLS_KEY"  "/opt/proxymon/certs/key.pem"
            log_info "TLS certificates migrated and configured."
        else
            log_warn "Certificate files copied but could not detect cert/key pair."
            log_warn "Use: proxymon set-certs --cert=<file> --key=<file>"
        fi
    fi

    cd "$PROXYMON_DIR"
    docker compose pull
    docker compose up -d

    log_info "Migration complete. ProxyMon is running."
    docker ps --filter name=proxymon --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_update() {
    log_info "Updating ProxyMon..."

    ensure_docker_mirror

    cd "$PROXYMON_DIR"
    docker compose pull
    docker compose up -d --force-recreate

    log_info "ProxyMon updated."
    docker ps --filter name=proxymon --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_edit() {
    local key="$1"
    local value="$2"

    if [ -z "$key" ] || [ -z "$value" ]; then
        log_error "Usage: proxymon edit <KEY> <VALUE>"
        exit 1
    fi

    mkdir -p "$PROXYMON_DIR"
    set_env_var "$key" "$value"
    log_info "Set ${key}=${value} in .env"

    if [ -f "$COMPOSE_FILE" ]; then
        cd "$PROXYMON_DIR"
        docker compose up -d --force-recreate 2>/dev/null && \
            log_info "Container restarted with new configuration." || \
            log_warn "Container restart skipped (not running yet)."
    fi
}

cmd_gen_certs() {
    local cn="proxymon" days="3650"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cn=*)   cn="${1#*=}"; shift ;;
            --cn)     cn="$2"; shift 2 ;;
            --days=*) days="${1#*=}"; shift ;;
            --days)   days="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if ! command -v openssl &>/dev/null; then
        log_info "Installing openssl..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl 2>/dev/null
    fi

    mkdir -p "$CERTS_DIR"

    openssl req -x509 -nodes -days "$days" -newkey rsa:2048 \
        -keyout "$CERTS_DIR/key.pem" \
        -out "$CERTS_DIR/cert.pem" \
        -subj "/CN=$cn" 2>/dev/null

    chmod 600 "$CERTS_DIR/cert.pem" "$CERTS_DIR/key.pem"

    set_env_var "TLS_CERT" "/opt/proxymon/certs/cert.pem"
    set_env_var "TLS_KEY"  "/opt/proxymon/certs/key.pem"

    log_info "Self-signed certificate generated (CN=$cn, valid $days days)"
    log_info "  cert: $CERTS_DIR/cert.pem"
    log_info "  key:  $CERTS_DIR/key.pem"

    if [ -f "$COMPOSE_FILE" ]; then
        cd "$PROXYMON_DIR"
        docker compose up -d --force-recreate 2>/dev/null && \
            log_info "Container restarted with TLS enabled." || \
            log_warn "Container restart skipped (not running yet)."
    fi
}

cmd_set_certs() {
    local cert_src="" key_src=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cert=*) cert_src="${1#*=}"; shift ;;
            --cert)   cert_src="$2"; shift 2 ;;
            --key=*)  key_src="${1#*=}"; shift ;;
            --key)    key_src="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "$cert_src" ] || [ -z "$key_src" ]; then
        log_error "Usage: proxymon set-certs --cert=<path> --key=<path>"
        exit 1
    fi

    if [ ! -f "$cert_src" ]; then
        log_error "Certificate file not found: $cert_src"
        exit 1
    fi
    if [ ! -f "$key_src" ]; then
        log_error "Key file not found: $key_src"
        exit 1
    fi

    mkdir -p "$CERTS_DIR"
    cp "$cert_src" "$CERTS_DIR/cert.pem"
    cp "$key_src"  "$CERTS_DIR/key.pem"
    chmod 600 "$CERTS_DIR/cert.pem" "$CERTS_DIR/key.pem"

    set_env_var "TLS_CERT" "/opt/proxymon/certs/cert.pem"
    set_env_var "TLS_KEY"  "/opt/proxymon/certs/key.pem"

    log_info "Certificates installed to $CERTS_DIR"

    if [ -f "$COMPOSE_FILE" ]; then
        cd "$PROXYMON_DIR"
        docker compose up -d --force-recreate 2>/dev/null && \
            log_info "Container restarted with TLS enabled." || \
            log_warn "Container restart skipped (not running yet)."
    fi
}

cmd_set_cli() {
    local script_path
    script_path="$(readlink -f "$0")"
    local target="/usr/local/bin/proxymon"

    cp "$script_path" "$target"
    chmod +x "$target"

    log_info "proxymon CLI installed at $target"
    log_info "You can now run: proxymon <command>"
}

show_help() {
    echo "ProxyMon — Proxy monitoring API manager"
    echo ""
    echo "Usage: proxymon <command> [options]"
    echo ""
    echo "Commands:"
    echo "  install [--token=TOKEN]          Install ProxyMon from Docker image"
    echo "  migrate [--token=TOKEN]          Migrate from ansible version to Docker"
    echo "  update                           Pull latest image and restart"
    echo "  edit <KEY> <VALUE>               Change a variable in .env and restart"
    echo "  gen-certs [--cn=NAME]            Generate self-signed TLS certificate"
    echo "  set-certs --cert=F --key=F       Install existing TLS certificates"
    echo "  set-cli                          Register proxymon as a system-wide command"
    echo "  help                             Show this help message"
    echo ""
    echo "Examples:"
    echo "  proxymon install --token=my_secret_token"
    echo "  proxymon migrate --token=my_secret_token"
    echo "  proxymon update"
    echo "  proxymon edit TOKEN new_secret_value"
    echo "  proxymon edit API_PORT 8080"
    echo "  proxymon gen-certs"
    echo "  proxymon gen-certs --cn=myserver.com --days=365"
    echo "  proxymon set-certs --cert=/tmp/cert.pem --key=/tmp/key.pem"
    echo "  proxymon set-cli"
}

# ── Entrypoint ────────────────────────────────────────────────────

case "${1:-help}" in
    install)    shift; cmd_install "$@" ;;
    migrate)    shift; cmd_migrate "$@" ;;
    update)     cmd_update ;;
    edit)       shift; cmd_edit "$@" ;;
    gen-certs)  shift; cmd_gen_certs "$@" ;;
    set-certs)  shift; cmd_set_certs "$@" ;;
    set-cli)    cmd_set_cli ;;
    help|--help|-h) show_help ;;
    *) log_error "Unknown command: $1"; show_help; exit 1 ;;
esac
