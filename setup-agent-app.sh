#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$SCRIPT_DIR"
SERVICE_NAME="agent-app"
APP_DIR="$SERVER_ROOT/$SERVICE_NAME"
COMPOSE_FILE="$APP_DIR/compose.yaml"
ENV_FILE="$APP_DIR/.env"
PUBLIC_EDGE_DIR="$SERVER_ROOT/public-edge"
PUBLIC_EDGE_ENV_FILE="$PUBLIC_EDGE_DIR/.env"
PUBLIC_EDGE_COMPOSE_FILE="$PUBLIC_EDGE_DIR/compose.yaml"
PUBLIC_EDGE_INIT_SCRIPT="$PUBLIC_EDGE_DIR/init-server.sh"
REGISTER_SCRIPT="$SERVER_ROOT/public-edge/register-acme-dns-client.sh"
ACME_CLIENT_DIR="$SERVER_ROOT/volumes/acme-dns/clients"
ACME_CREDENTIAL_FILE="$ACME_CLIENT_DIR/${SERVICE_NAME}.env"
ACME_REGISTRATION_FILE="$ACME_CLIENT_DIR/${SERVICE_NAME}.registration.json"
ACME_DNS_CONFIG_FILE="$SERVER_ROOT/volumes/acme-dns/config/config.cfg"
ACME_DNS_API_HOST="127.0.0.1"
ACME_DNS_API_PORT="8080"
AUTHELIA_CONFIG_DIR="$SERVER_ROOT/volumes/agent-app/authelia/config"
AUTHELIA_SECRETS_DIR="$AUTHELIA_CONFIG_DIR/secrets"
AUTHELIA_CONFIG_FILE="$AUTHELIA_CONFIG_DIR/configuration.yml"
AUTHELIA_USERS_FILE="$AUTHELIA_CONFIG_DIR/users_database.yml"
AUTHELIA_NOTIFICATION_FILE="$AUTHELIA_CONFIG_DIR/notification.txt"
SMTP_DKIM_SELECTOR="mail"
SMTP_DKIM_DIR="$SERVER_ROOT/volumes/agent-app/smtp/opendkim"
SMTP_PROBE_HOST="gmail-smtp-in.l.google.com"
OPEN_AGENT_APP_SSH_PORT="${OPEN_AGENT_APP_SSH_PORT:-true}"
AGENT_APP_NOTIFICATION_MODE=""

DETACH=false
DNS_SKIP=false

log() {
    printf '[agent-app-setup] %s\n' "$*" >&2
}

die() {
    printf '[agent-app-setup] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  sudo $(basename "$0") [options]

Options:
  -d, --detach        Pass -d to docker compose up.
  --dns-skip          Do not register ACME DNS and do not wait after printing DNS records.
  -h, --help         Show this help.

Environment overrides:
  OPEN_AGENT_APP_SSH_PORT=true|false

The script reads ${PUBLIC_EDGE_ENV_FILE} and ${ENV_FILE} if they exist, asks for
missing values, keeps entered values in the current process environment only,
installs or updates the public-edge stack, waits for acme-dns to be ready,
registers the agent-app ACME DNS client if needed, generates the local SMTP
DKIM key when SMTP is enabled, prints the DNS records to create, waits for
confirmation unless skipped with --dns-skip, and runs:
  docker compose up [-d] --build --force-recreate --remove-orphans

Without --dns-skip, an existing agent-app ACME credential is reused only when
it was generated for the current AGENT_APP_DOMAIN. Otherwise it is recreated
and the printed DNS CNAME target must be updated. With --dns-skip, registration
is skipped completely even if no credential file exists.

The script also generates the single-user Authelia config under:
  ${AUTHELIA_CONFIG_DIR}
and the SMTP DKIM key, when SMTP is enabled, under:
  ${SMTP_DKIM_DIR}
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--detach)
                DETACH=true
                ;;
            --dns-skip)
                DNS_SKIP=true
                ;;
            -h|--help|help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script with sudo or as root."
}

require_files() {
    [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: ${COMPOSE_FILE}"
    [[ -f "$PUBLIC_EDGE_COMPOSE_FILE" ]] ||
        die "public-edge compose file not found: ${PUBLIC_EDGE_COMPOSE_FILE}. Copy public-edge server-root files first."
    [[ -f "$PUBLIC_EDGE_INIT_SCRIPT" ]] ||
        die "public-edge init script not found: ${PUBLIC_EDGE_INIT_SCRIPT}. Copy public-edge server-root files first."
    [[ -f "$REGISTER_SCRIPT" ]] ||
        die "ACME registration script not found: ${REGISTER_SCRIPT}. Install public-edge first."
}

load_env_file() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0

    log "Loading existing environment file: ${env_file}"
    set +u
    set -a
    # shellcheck disable=SC1090
    . <(tr -d '\r' <"$env_file")
    set +a
    set -u
}

validate_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_email() {
    [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

validate_username() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_auto_bool() {
    local value="${1,,}"
    [[ "$value" == "auto" || "$value" == "true" || "$value" == "false" ]]
}

validate_auth_domain() {
    local value="$1"
    local prefix

    validate_domain "$value" || return 1
    [[ -n "${AGENT_APP_DOMAIN:-}" ]] || return 1
    [[ "$value" == *".${AGENT_APP_DOMAIN}" ]] || return 1

    prefix="${value%."$AGENT_APP_DOMAIN"}"
    [[ -n "$prefix" && "$prefix" != *.* && ! "$prefix" =~ ^[0-9]+$ ]]
}

read_value() {
    local prompt="$1"
    local secret="$2"
    local value

    if [[ "$secret" == "true" && -t 0 ]]; then
        read -r -s -p "$prompt" value
        printf '\n' >&2
    else
        read -r -p "$prompt" value
    fi

    printf '%s' "$value"
}

ensure_env() {
    local key="$1"
    local required="$2"
    local prompt="$3"
    local validator="${4:-}"
    local secret="${5:-false}"
    local default_value="${6:-}"
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
        value="$(read_value "$prompt" "$secret")"
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

agent_app_ssh_bind_default() {
    if [[ "$OPEN_AGENT_APP_SSH_PORT" == "true" ]]; then
        printf '0.0.0.0'
    else
        printf '127.0.0.1'
    fi
}

outbound_smtp25_available() {
    command -v timeout >/dev/null 2>&1 || return 1
    timeout 8 bash -c "</dev/tcp/${SMTP_PROBE_HOST}/25" >/dev/null 2>&1
}

configure_notification_mode() {
    local requested="${AGENT_APP_ENABLE_SMTP:-auto}"

    if [[ -z "$requested" ]]; then
        requested="auto"
    fi

    requested="${requested,,}"
    validate_auto_bool "$requested" ||
        die "AGENT_APP_ENABLE_SMTP must be one of: auto, true, false."

    export AGENT_APP_ENABLE_SMTP="$requested"

    case "$requested" in
        true)
            AGENT_APP_NOTIFICATION_MODE="smtp"
            log "SMTP notifications are explicitly enabled."
            ;;
        false)
            AGENT_APP_NOTIFICATION_MODE="filesystem"
            log "SMTP notifications are explicitly disabled; Authelia notifications will be written to a file."
            ;;
        auto)
            log "Checking outbound TCP/25 to decide notification mode."
            if outbound_smtp25_available; then
                AGENT_APP_NOTIFICATION_MODE="smtp"
                log "Outbound TCP/25 is reachable; SMTP notifications are enabled."
            else
                AGENT_APP_NOTIFICATION_MODE="filesystem"
                log "Outbound TCP/25 is blocked or unreachable; Authelia notifications will be written to a file."
            fi
            ;;
    esac

    export AGENT_APP_NOTIFICATION_MODE
}

smtp_notifications_enabled() {
    [[ "$AGENT_APP_NOTIFICATION_MODE" == "smtp" ]]
}

configure_env() {
    local ssh_bind_default

    mkdir -p "$APP_DIR"
    load_env_file "$PUBLIC_EDGE_ENV_FILE"
    load_env_file "$ENV_FILE"
    ssh_bind_default="$(agent_app_ssh_bind_default)"

    ensure_env AGENT_APP_DOMAIN true \
        "AGENT_APP_DOMAIN, for example agent.example.com: " validate_domain
    ensure_env ADMIN_EMAIL true \
        "ADMIN_EMAIL, for example admin@example.com: " validate_email
    ensure_env AGENT_APP_AUTH_DOMAIN true \
        "AGENT_APP_AUTH_DOMAIN, default auth.${AGENT_APP_DOMAIN}: " validate_auth_domain false "auth.${AGENT_APP_DOMAIN}"
    ensure_env AGENT_APP_AUTH_USERNAME true \
        "AGENT_APP_AUTH_USERNAME for Authelia login: " validate_username
    ensure_env AGENT_APP_AUTH_PASSWORD true \
        "AGENT_APP_AUTH_PASSWORD for Authelia login: " "" true

    configure_notification_mode

    if smtp_notifications_enabled; then
        ensure_env AGENT_APP_SMTP_DOMAIN true \
            "AGENT_APP_SMTP_DOMAIN, default ${AGENT_APP_DOMAIN}: " validate_domain false "$AGENT_APP_DOMAIN"
    fi

    ensure_env AGENT_APP_SSH_BIND false \
        "Optional AGENT_APP_SSH_BIND, default ${ssh_bind_default}, Enter to use default: " "" false "$ssh_bind_default"
    ensure_env AGENT_APP_SSH_PORT false \
        "Optional AGENT_APP_SSH_PORT, default 2222, Enter to skip: " validate_port
    ensure_env AGENT_APP_AUTHORIZED_KEYS false \
        "Optional AGENT_APP_AUTHORIZED_KEYS public key, Enter to skip: "
    ensure_env AGENT_APP_PASSWORD false \
        "Optional AGENT_APP_PASSWORD for SSH password login, Enter to skip: " "" true
    ensure_env TZ false \
        "Optional TZ, default Asia/Jerusalem, Enter to skip: "
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH."
    docker compose version >/dev/null 2>&1 || die "docker compose plugin is not available."
}

ensure_public_edge() {
    log "Installing or updating public-edge before ACME registration."
    bash "$PUBLIC_EDGE_INIT_SCRIPT" install
    require_docker
}

yaml_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

read_or_create_secret() {
    local file="$1"
    local bytes="$2"

    mkdir -p "$(dirname "$file")"

    if [[ ! -s "$file" ]]; then
        command -v openssl >/dev/null 2>&1 || die "openssl is required to generate Authelia secrets."
        openssl rand -hex "$bytes" >"$file"
        chmod 0600 "$file"
    fi

    tr -d '\r\n' <"$file"
}

compose_service_image() {
    local service="$1"
    local image

    image="$(
        awk -v service="$service" '
            $0 ~ "^  " service ":" {
                in_service = 1
                next
            }
            in_service && /^  [A-Za-z0-9_.-]+:/ {
                in_service = 0
            }
            in_service && /^[[:space:]]+image:[[:space:]]*/ {
                sub(/^[[:space:]]*image:[[:space:]]*/, "")
                gsub(/["'\'']/, "")
                gsub(/\r/, "")
                sub(/[[:space:]]+$/, "")
                print
                exit
            }
        ' "$COMPOSE_FILE"
    )"

    [[ -n "$image" ]] || die "Could not read ${service} image from ${COMPOSE_FILE}."
    printf '%s' "$image" | tr -d '\r'
}

authelia_password_hash() {
    local output
    local digest
    local image

    image="$(compose_service_image agent-app-authelia)"
    [[ -n "$image" ]] || die "Could not read agent-app-authelia image from ${COMPOSE_FILE}."
    log "Generating Authelia password hash with ${image}."
    output="$(
        docker run --rm "$image" \
            authelia crypto hash generate argon2 \
            --password "$AGENT_APP_AUTH_PASSWORD" \
            --no-confirm
    )"
    digest="$(printf '%s\n' "$output" | sed -n 's/^Digest: //p' | head -n 1)"
    [[ -n "$digest" ]] || die "Could not generate Authelia password hash."

    printf '%s' "$digest"
}

ensure_smtp_dkim_key() {
    local image

    if ! smtp_notifications_enabled; then
        log "Skipping SMTP DKIM key generation because SMTP notifications are disabled."
        return 0
    fi

    mkdir -p "$SMTP_DKIM_DIR"

    if [[ -s "$SMTP_DKIM_DIR/${AGENT_APP_SMTP_DOMAIN}.private" && -s "$SMTP_DKIM_DIR/${AGENT_APP_SMTP_DOMAIN}.txt" ]]; then
        log "SMTP DKIM key already exists for ${AGENT_APP_SMTP_DOMAIN}."
        return 0
    fi

    image="$(compose_service_image agent-app-smtp)"
    [[ -n "$image" ]] || die "Could not read agent-app-smtp image from ${COMPOSE_FILE}."
    log "Generating SMTP DKIM key for ${AGENT_APP_SMTP_DOMAIN} with ${image}."
    docker run --rm \
        --entrypoint sh \
        -e DKIM_DOMAIN="$AGENT_APP_SMTP_DOMAIN" \
        -e DKIM_SELECTOR="$SMTP_DKIM_SELECTOR" \
        -v "$SMTP_DKIM_DIR:/keys" \
        "$image" \
        -ec '
            cd /keys
            rm -f "${DKIM_SELECTOR}.private" "${DKIM_SELECTOR}.txt"
            opendkim-genkey -b 2048 -h rsa-sha256 -r -v --subdomains -s "${DKIM_SELECTOR}" -d "${DKIM_DOMAIN}"
            sed -i "s/h=rsa-sha256/h=sha256/" "${DKIM_SELECTOR}.txt" || true
            mv "${DKIM_SELECTOR}.private" "${DKIM_DOMAIN}.private"
            mv "${DKIM_SELECTOR}.txt" "${DKIM_DOMAIN}.txt"
            chmod 0600 "${DKIM_DOMAIN}.private"
            chmod 0644 "${DKIM_DOMAIN}.txt"
        '
}

smtp_dkim_dns_value() {
    local file="$SMTP_DKIM_DIR/${AGENT_APP_SMTP_DOMAIN}.txt"

    [[ -f "$file" ]] ||
        die "SMTP DKIM TXT file not found: ${file}"

    awk '
        {
            while (match($0, /"[^"]+"/)) {
                printf "%s", substr($0, RSTART + 1, RLENGTH - 2)
                $0 = substr($0, RSTART + RLENGTH)
            }
        }
        END {
            printf "\n"
        }
    ' "$file"
}

ensure_authelia_config() {
    local jwt_secret
    local session_secret
    local storage_key
    local password_hash

    mkdir -p "$AUTHELIA_CONFIG_DIR" "$AUTHELIA_SECRETS_DIR"

    jwt_secret="$(read_or_create_secret "$AUTHELIA_SECRETS_DIR/jwt_secret" 32)"
    session_secret="$(read_or_create_secret "$AUTHELIA_SECRETS_DIR/session_secret" 32)"
    storage_key="$(read_or_create_secret "$AUTHELIA_SECRETS_DIR/storage_encryption_key" 32)"
    password_hash="$(authelia_password_hash)"

    cat >"$AUTHELIA_CONFIG_FILE" <<EOF
theme: auto
default_2fa_method: totp

server:
  address: tcp://:9091/

log:
  level: info

totp:
  disable: false
  issuer: $(yaml_quote "$AGENT_APP_AUTH_DOMAIN")

identity_validation:
  reset_password:
    jwt_secret: $(yaml_quote "$jwt_secret")

authentication_backend:
  file:
    path: /config/users_database.yml
    watch: false
    search:
      email: false
      case_insensitive: false

access_control:
  default_policy: deny
  rules:
    - domain:
        - $(yaml_quote "$AGENT_APP_DOMAIN")
        - $(yaml_quote "*.${AGENT_APP_DOMAIN}")
      policy: two_factor

session:
  secret: $(yaml_quote "$session_secret")
  cookies:
    - domain: $(yaml_quote "$AGENT_APP_DOMAIN")
      authelia_url: $(yaml_quote "https://${AGENT_APP_AUTH_DOMAIN}")
      default_redirection_url: $(yaml_quote "https://${AGENT_APP_DOMAIN}")
      same_site: lax
      inactivity: $(yaml_quote "${AGENT_APP_AUTH_SESSION_INACTIVITY:-12h}")
      expiration: $(yaml_quote "${AGENT_APP_AUTH_SESSION_EXPIRATION:-1d}")
      remember_me: $(yaml_quote "${AGENT_APP_AUTH_SESSION_REMEMBER_ME:-1M}")

storage:
  encryption_key: $(yaml_quote "$storage_key")
  local:
    path: /config/db.sqlite3
EOF

    if smtp_notifications_enabled; then
        cat >>"$AUTHELIA_CONFIG_FILE" <<EOF
notifier:
  smtp:
    address: smtp://agent-app-smtp:25
    sender: $(yaml_quote "Authelia <authelia@${AGENT_APP_SMTP_DOMAIN}>")
    identifier: $(yaml_quote "$AGENT_APP_SMTP_DOMAIN")
    subject: $(yaml_quote "[Authelia] {title}")
    startup_check_address: $(yaml_quote "$ADMIN_EMAIL")
    disable_require_tls: true
EOF
    else
        touch "$AUTHELIA_NOTIFICATION_FILE"
        chmod 0600 "$AUTHELIA_NOTIFICATION_FILE"

        cat >>"$AUTHELIA_CONFIG_FILE" <<EOF
notifier:
  filesystem:
    filename: /config/notification.txt
EOF
    fi

    cat >"$AUTHELIA_USERS_FILE" <<EOF
users:
  $(yaml_quote "$AGENT_APP_AUTH_USERNAME"):
    disabled: false
    displayname: $(yaml_quote "$AGENT_APP_AUTH_USERNAME")
    password: $(yaml_quote "$password_hash")
    email: $(yaml_quote "$ADMIN_EMAIL")
    groups:
      - admins
EOF

    chmod 0600 "$AUTHELIA_CONFIG_FILE" "$AUTHELIA_USERS_FILE"
    log "Wrote Authelia config for ${AGENT_APP_AUTH_DOMAIN}."
}

configure_firewall() {
    local ssh_bind="${AGENT_APP_SSH_BIND:-127.0.0.1}"
    local ssh_port="${AGENT_APP_SSH_PORT:-2222}"

    [[ "$OPEN_AGENT_APP_SSH_PORT" == "true" ]] || {
        log "Skipping Agent App SSH firewall rule."
        return
    }

    if ! command -v ufw >/dev/null 2>&1; then
        log "UFW is not installed; skipping Agent App SSH firewall rule."
        return
    fi

    log "Opening UFW port ${ssh_port}/tcp for Agent App SSH."
    ufw allow "${ssh_port}/tcp" >/dev/null

    if [[ "$ssh_bind" == "127.0.0.1" || "$ssh_bind" == "localhost" || "$ssh_bind" == "::1" ]]; then
        log "Agent App SSH is bound to ${ssh_bind}; set AGENT_APP_SSH_BIND=0.0.0.0 to accept remote SSH."
    fi
}

wait_for_acme_dns_api() {
    local attempt

    log "Waiting for acme-dns registration API on ${ACME_DNS_API_HOST}:${ACME_DNS_API_PORT}."

    for attempt in {1..60}; do
        if (: >"/dev/tcp/${ACME_DNS_API_HOST}/${ACME_DNS_API_PORT}") >/dev/null 2>&1; then
            log "acme-dns registration API is ready."
            return 0
        fi

        sleep 2
    done

    (
        cd "$PUBLIC_EDGE_DIR"
        docker compose -f "$PUBLIC_EDGE_COMPOSE_FILE" ps || true
    )
    die "Timed out waiting for acme-dns registration API."
}

ensure_acme_registration() {
    mkdir -p "$ACME_CLIENT_DIR"

    if [[ "$DNS_SKIP" == "true" ]]; then
        log "Skipping ACME DNS registration because --dns-skip was used."
        if [[ ! -s "$ACME_CREDENTIAL_FILE" ]]; then
            log "No ACME DNS credential file exists at ${ACME_CREDENTIAL_FILE}; docker compose may fail until you provide it."
        fi
        return 0
    fi

    if [[ -s "$ACME_CREDENTIAL_FILE" ]]; then
        if acme_credential_matches_domain; then
            log "ACME DNS credential already matches ${AGENT_APP_DOMAIN}; skipping registration."
            return 0
        fi

        log "ACME DNS credential does not match ${AGENT_APP_DOMAIN}; recreating registration."
        rm -f "$ACME_CREDENTIAL_FILE" "$ACME_REGISTRATION_FILE"
    else
        rm -f "$ACME_REGISTRATION_FILE"
    fi

    log "Registering ACME DNS client for ${SERVICE_NAME}."
    bash "$REGISTER_SCRIPT" "$SERVICE_NAME" "_acme-challenge.${AGENT_APP_DOMAIN}"
    append_acme_registration_metadata
}

acme_credential_matches_domain() {
    grep -Fq "ACMESH_DNS_API_CONFIG=" "$ACME_CREDENTIAL_FILE" 2>/dev/null &&
        grep -Fqx "# AGENT_APP_DOMAIN=${AGENT_APP_DOMAIN}" "$ACME_CREDENTIAL_FILE" 2>/dev/null
}

append_acme_registration_metadata() {
    [[ -s "$ACME_CREDENTIAL_FILE" ]] ||
        die "ACME registration did not create credential file: ${ACME_CREDENTIAL_FILE}"

    cat >>"$ACME_CREDENTIAL_FILE" <<EOF

# Agent App setup metadata. Used to detect stale ACME registrations.
# AGENT_APP_DOMAIN=${AGENT_APP_DOMAIN}
EOF
    chmod 0600 "$ACME_CREDENTIAL_FILE"
}

json_field() {
    local field="$1"
    local file="$2"
    sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file"
}

acme_cname_target() {
    local target=""

    if [[ -f "$ACME_REGISTRATION_FILE" ]]; then
        target="$(json_field fulldomain "$ACME_REGISTRATION_FILE" | head -n 1)"
    fi

    if [[ -n "$target" && "$target" != *. ]]; then
        target="${target}."
    fi

    printf '%s' "$target"
}

config_value() {
    local key="$1"
    local file="$2"

    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

acme_dns_domain() {
    local domain

    [[ -f "$ACME_DNS_CONFIG_FILE" ]] ||
        die "acme-dns config file not found: ${ACME_DNS_CONFIG_FILE}"

    domain="$(config_value domain "$ACME_DNS_CONFIG_FILE")"
    [[ -n "$domain" ]] ||
        die "Could not read acme-dns domain from ${ACME_DNS_CONFIG_FILE}."

    printf '%s' "$domain"
}

acme_dns_nsname() {
    local nsname

    [[ -f "$ACME_DNS_CONFIG_FILE" ]] ||
        die "acme-dns config file not found: ${ACME_DNS_CONFIG_FILE}"

    nsname="$(config_value nsname "$ACME_DNS_CONFIG_FILE")"
    if [[ -z "$nsname" ]]; then
        nsname="$(acme_dns_domain)"
    fi

    printf '%s' "$nsname"
}

with_trailing_dot() {
    local value="$1"

    if [[ "$value" == *. ]]; then
        printf '%s' "$value"
    else
        printf '%s.' "$value"
    fi
}

detect_public_ip() {
    local ip=""

    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$ip"
    else
        printf '<server-public-ip>'
    fi
}

print_dns_records() {
    local public_ip="$1"
    local cname_target="$2"
    local acme_domain="$3"
    local acme_nsname="$4"

    [[ -n "$cname_target" ]] ||
        cname_target="<acme-dns target from ${ACME_REGISTRATION_FILE}>"

    cat <<EOF

Create or verify these DNS records before Agent App starts:

| Type  | Name/FQDN                         | Value        | Purpose |
|-------|-----------------------------------|--------------|---------|
| A     | ${acme_nsname}                    | ${public_ip} | ACME DNS authoritative host |
| NS    | ${acme_domain}                    | $(with_trailing_dot "$acme_nsname") | Delegate ACME DNS zone |
| A     | ${AGENT_APP_DOMAIN}               | ${public_ip} | Base Agent App UI |
| A     | ${AGENT_APP_AUTH_DOMAIN}          | ${public_ip} | Authelia login portal |
| A     | *.${AGENT_APP_DOMAIN}             | ${public_ip} | Dynamic port subdomains |
| CNAME | _acme-challenge.${AGENT_APP_DOMAIN} | ${cname_target} | Let's Encrypt DNS-01 validation |
EOF

    if smtp_notifications_enabled; then
        local dkim_value

        dkim_value="$(smtp_dkim_dns_value)"

        if [[ "$AGENT_APP_SMTP_DOMAIN" != "$AGENT_APP_DOMAIN" && "$AGENT_APP_SMTP_DOMAIN" != "$AGENT_APP_AUTH_DOMAIN" ]]; then
            printf '| A     | %s          | %s | SMTP sending domain |\n' "$AGENT_APP_SMTP_DOMAIN" "$public_ip"
        fi

        cat <<EOF
| TXT   | ${AGENT_APP_SMTP_DOMAIN}          | v=spf1 ip4:${public_ip} -all | SPF: allow this server to send mail |
| TXT   | ${SMTP_DKIM_SELECTOR}._domainkey.${AGENT_APP_SMTP_DOMAIN} | ${dkim_value} | DKIM public key |
| TXT   | _dmarc.${AGENT_APP_SMTP_DOMAIN}   | v=DMARC1; p=none; adkim=s; aspf=s | DMARC policy |
EOF
    fi

    cat <<EOF

If your DNS manager asks for a relative Host/Name instead of a full name,
enter the left side relative to the DNS zone you manage.

EOF

    if smtp_notifications_enabled; then
        cat <<EOF
The SMTP container is send-only and has no host-published ports. Delivery still
requires outbound TCP/25 from this server to the internet. Some VPS providers
block outbound TCP/25; if mail never arrives, check the provider firewall or use
an external SMTP relay.
EOF
    else
        cat <<EOF
SMTP notifications are disabled. Authelia codes and registration links will be
written to:
  ${AUTHELIA_NOTIFICATION_FILE}

Follow the notification file with:
  sudo tail -n +1 -F ${AUTHELIA_NOTIFICATION_FILE}
EOF
    fi
}

wait_for_dns_confirmation() {
    if [[ "$DNS_SKIP" == "true" ]]; then
        log "Skipping DNS confirmation wait because --dns-skip was used."
        return 0
    fi

    printf '\nPress Enter after the DNS records are created and propagated... '
    read -r _
}

compose_up() {
    local args=(up --build --force-recreate --remove-orphans)
    local compose_profiles="notifications"

    if [[ "$DETACH" == "true" ]]; then
        args=(up -d --build --force-recreate --remove-orphans)
    fi

    if smtp_notifications_enabled; then
        compose_profiles="smtp"
    fi

    log "Starting or updating ${SERVICE_NAME} with docker compose."
    (
        cd "$APP_DIR"
        export COMPOSE_PROFILES="$compose_profiles"
        docker compose "${args[@]}"
    )
}

main() {
    parse_args "$@"
    require_root
    require_files
    configure_env
    ensure_public_edge
    ensure_smtp_dkim_key
    ensure_authelia_config
    configure_firewall
    wait_for_acme_dns_api
    ensure_acme_registration
    print_dns_records "$(detect_public_ip)" "$(acme_cname_target)" "$(acme_dns_domain)" "$(acme_dns_nsname)"
    wait_for_dns_confirmation
    compose_up
}

main "$@"
