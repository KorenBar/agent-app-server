#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
REGISTER_SCRIPT="$SCRIPT_DIR/register-acme-dns-client.sh"
COMPOSE_ENV_FILE="$SCRIPT_DIR/.env"
SERVER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VOLUMES_DIR="$SERVER_ROOT/volumes"
ACME_DNS_CONFIG_FILE="$VOLUMES_DIR/acme-dns/config/config.cfg"
ENABLE_UFW="${ENABLE_UFW:-true}"
INSTALL_DOCKER_GROUP="${INSTALL_DOCKER_GROUP:-true}"

log() {
    printf '[public-edge-init] %s\n' "$*"
}

die() {
    printf '[public-edge-init] ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run this script with sudo or as root."
    fi
}

usage() {
    cat <<EOF
Usage:
  sudo $(basename "$0") install
  sudo $(basename "$0") prepare-cutover
  sudo $(basename "$0") update
  sudo $(basename "$0") status
  sudo $(basename "$0") logs [service...]

Environment overrides:
  ADMIN_EMAIL=<email>                 Shared ACME contact email.
  ACME_DNS_DOMAIN=<domain>            Delegated acme-dns zone.
  ACME_DNS_NSNAME=<domain>            Optional authoritative NS host.
  ACME_DNS_NSADMIN=<soa-rname>        Optional SOA admin name.
  ENABLE_UFW=true|false
  INSTALL_DOCKER_GROUP=true|false
  ACME_DNS_BIND_IP=<local-ipv4>  Override automatic acme-dns listener detection.

Commands:
  install          Install Docker if needed, configure base firewall rules,
                   pull images, and start the shared reverse proxy stack.
  prepare-cutover  Install Docker if needed, configure base firewall rules,
                   pull images, and create containers/network without starting
                   them. Use this when another nginx still owns ports 80/443.
  update           Validate, pull, and recreate the shared reverse proxy stack.
  status           Show Docker, compose, network, socket, firewall, and stack status.
  logs             Tail compose logs.
EOF
}

check_ubuntu() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only."
}

install_base_packages() {
    log "Installing base packages."
    apt-get update
    apt-get install -y ca-certificates curl git gnupg lsb-release ufw
}

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log "Docker Engine and Compose plugin already installed."
        return
    fi

    log "Installing Docker repository."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    . /etc/os-release
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    log "Installing Docker Engine and Compose plugin."
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

load_env_file() {
    [[ -f "$COMPOSE_ENV_FILE" ]] || return 0

    log "Loading existing environment file: ${COMPOSE_ENV_FILE}"
    set +u
    set -a
    # shellcheck disable=SC1090
    . "$COMPOSE_ENV_FILE"
    set +a
    set -u
}

validate_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

email_to_soa_admin() {
    printf '%s' "${1/@/.}"
}

read_value() {
    local prompt="$1"
    local value

    read -r -p "$prompt" value
    printf '%s' "$value"
}

ensure_env() {
    local key="$1"
    local required="$2"
    local prompt="$3"
    local validator="${4:-}"
    local default_value="${5:-}"
    local current="${!key:-}"
    local value

    if [[ -n "$current" ]]; then
        if [[ -n "$validator" ]] && ! "$validator" "$current"; then
            log "Existing ${key} is invalid; asking for a replacement."
        else
            export "$key"
            log "Using existing ${key} from .env or environment."
            return 0
        fi
    fi

    while true; do
        value="$(read_value "$prompt")"
        if [[ -z "$value" && -n "$default_value" ]]; then
            value="$default_value"
        fi

        if [[ -z "$value" ]]; then
            if [[ "$required" == "true" ]]; then
                log "${key} is required."
                continue
            fi
            unset "$key"
            return 0
        fi

        if [[ -n "$validator" ]] && ! "$validator" "$value"; then
            log "Invalid value for ${key}."
            continue
        fi

        printf -v "$key" '%s' "$value"
        export "$key"
        return 0
    done
}

configure_public_edge_env() {
    load_env_file

    ensure_env ADMIN_EMAIL true \
        "ADMIN_EMAIL, for example admin@example.com: " validate_email
    ensure_env ACME_DNS_DOMAIN true \
        "ACME_DNS_DOMAIN, for example authdns.example.com: " validate_domain
    ensure_env ACME_DNS_NSNAME false \
        "Optional ACME_DNS_NSNAME, default ${ACME_DNS_DOMAIN}: " validate_domain "$ACME_DNS_DOMAIN"
    ensure_env ACME_DNS_NSADMIN false \
        "Optional ACME_DNS_NSADMIN, default $(email_to_soa_admin "$ADMIN_EMAIL"): " validate_domain "$(email_to_soa_admin "$ADMIN_EMAIL")"
}

configure_docker_group() {
    [[ "$INSTALL_DOCKER_GROUP" == "true" ]] || return

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        log "Adding ${SUDO_USER} to the docker group."
        usermod -aG docker "$SUDO_USER" || true
    fi
}

ensure_volume_dirs() {
    log "Preparing local proxy volume directories."
    install -d -m 0755 \
        "$VOLUMES_DIR/acme" \
        "$VOLUMES_DIR/acme-dns/config" \
        "$VOLUMES_DIR/acme-dns/data" \
        "$VOLUMES_DIR/acme-dns/clients" \
        "$VOLUMES_DIR/certs" \
        "$VOLUMES_DIR/conf.d" \
        "$VOLUMES_DIR/dhparam" \
        "$VOLUMES_DIR/html" \
        "$VOLUMES_DIR/vhost.d"
}

normalize_line_endings() {
    log "Normalizing line endings."
    sed -i 's/\r$//' "$COMPOSE_FILE" "$SCRIPT_DIR/$(basename "$0")" "$REGISTER_SCRIPT"
}

configure_acme_dns_bind_ip() {
    local bind_ip="${ACME_DNS_BIND_IP:-}"

    if [[ -n "$bind_ip" ]]; then
        log "Using ACME_DNS_BIND_IP override: ${bind_ip}."
    else
        if ! bind_ip="$(
            ip -4 route get 1.1.1.1 2>/dev/null |
                awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
        )"; then
            die "Could not inspect the outbound IPv4 route for acme-dns."
        fi
        [[ -n "$bind_ip" ]] ||
            die "Could not detect the external-facing IPv4 interface for acme-dns."
        log "Detected the acme-dns listener interface IPv4: ${bind_ip}."
    fi

    [[ "$bind_ip" != 127.* ]] ||
        die "Refusing to publish acme-dns on loopback address ${bind_ip}."

    if ! ip -4 -o address show |
        awk -v target="$bind_ip" '
            { split($4, address, "/") }
            address[1] == target { found = 1 }
            END { exit found ? 0 : 1 }
        '; then
        die "ACME_DNS_BIND_IP ${bind_ip} is not assigned to a local IPv4 interface."
    fi

    ACME_DNS_BIND_IP="$bind_ip"
    export ACME_DNS_BIND_IP
    log "Using ACME_DNS_BIND_IP for this run: ${ACME_DNS_BIND_IP}."
}

with_trailing_dot() {
    local value="$1"

    if [[ "$value" == *. ]]; then
        printf '%s' "$value"
    else
        printf '%s.' "$value"
    fi
}

write_acme_dns_config() {
    log "Writing acme-dns config from environment."

    cat >"$ACME_DNS_CONFIG_FILE" <<EOF
[general]
listen = "0.0.0.0:53"
protocol = "both"
domain = "${ACME_DNS_DOMAIN}"
nsname = "${ACME_DNS_NSNAME}"
nsadmin = "${ACME_DNS_NSADMIN}"
records = [
    "$(with_trailing_dot "$ACME_DNS_DOMAIN") NS $(with_trailing_dot "$ACME_DNS_NSNAME")",
]
debug = false

[database]
engine = "sqlite"
connection = "/var/lib/acme-dns/acme-dns.db"

[api]
ip = "0.0.0.0"
disable_registration = false
port = "8080"
tls = "none"
corsorigins = []
use_header = false
header_name = "X-Forwarded-For"

[logconfig]
loglevel = "info"
logtype = "stdout"
logformat = "text"
EOF
}

configure_ufw() {
    [[ "$ENABLE_UFW" == "true" ]] || {
        log "Skipping UFW configuration."
        return
    }

    log "Configuring UFW rules for the public edge."
    ufw allow OpenSSH >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 53/tcp >/dev/null
    ufw allow 53/udp >/dev/null

    if ! ufw status | grep -q "Status: active"; then
        log "Enabling UFW."
        ufw --force enable >/dev/null
    fi
}

compose_validate() {
    log "Validating compose file."
    docker compose -f "$COMPOSE_FILE" config >/dev/null
}

compose_pull() {
    log "Pulling images."
    docker compose -f "$COMPOSE_FILE" pull
}

compose_up() {
    log "Starting or updating shared reverse proxy stack."
    docker compose -f "$COMPOSE_FILE" up -d --remove-orphans
}

compose_create() {
    log "Creating shared reverse proxy containers and network without starting them."
    docker compose -f "$COMPOSE_FILE" create
}

show_status() {
    log "Docker service status."
    systemctl --no-pager --full status docker || true
    echo

    log "Docker version."
    docker version || true
    echo

    log "Compose version."
    docker compose version || true
    echo

    log "Reverse proxy network."
    docker network inspect reverse_proxy >/dev/null 2>&1 && echo "reverse_proxy exists" || echo "reverse_proxy missing"
    echo

    log "Compose services."
    docker compose -f "$COMPOSE_FILE" ps || true
    echo

    log "Listening sockets for public edge ports."
    ss -lntup | grep -E ':53|:80|:443' || true
    echo

    if command -v ufw >/dev/null 2>&1; then
        log "UFW status."
        ufw status verbose || true
    fi
}

show_logs() {
    local services=("$@")

    if [[ ${#services[@]} -eq 0 ]]; then
        docker compose -f "$COMPOSE_FILE" logs -f
    else
        docker compose -f "$COMPOSE_FILE" logs -f "${services[@]}"
    fi
}

main_prepare_host() {
    require_root
    check_ubuntu
    configure_public_edge_env
    install_base_packages
    install_docker
    configure_docker_group
    ensure_volume_dirs
    normalize_line_endings
    configure_acme_dns_bind_ip
    write_acme_dns_config
    configure_ufw
    compose_validate
    compose_pull
}

main_install() {
    main_prepare_host
    compose_up
    show_status
}

main_prepare_cutover() {
    main_prepare_host
    compose_create
    show_status
}

main_update() {
    require_root
    configure_public_edge_env
    ensure_volume_dirs
    normalize_line_endings
    configure_acme_dns_bind_ip
    write_acme_dns_config
    configure_ufw
    compose_validate
    compose_pull
    compose_up
    show_status
}

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        install)
            main_install
            ;;
        prepare-cutover)
            main_prepare_cutover
            ;;
        update)
            main_update
            ;;
        status)
            require_root
            show_status
            ;;
        logs)
            require_root
            show_logs "$@"
            ;;
        ""|-h|--help|help)
            usage
            ;;
        *)
            die "Unknown command: $command"
            ;;
    esac
}

main "$@"
