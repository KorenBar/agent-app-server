#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PASEO_USER="paseo"
PASEO_HOME="/home/${PASEO_USER}"
PASEO_WORKSPACE="/workspace"
PASEO_NPM_PREFIX="${PASEO_HOME}/.npm-global"
SYSTEM_NPM_ROOT="/usr/local/lib/node_modules"
PLAYWRIGHT_BROWSERS_PATH="/opt/ms-playwright"
SSHD_DROP_IN="/etc/ssh/sshd_config.d/00-paseo.conf"
SUDOERS_FILE="/etc/sudoers.d/99-paseo-password"
PROFILE_FILE="/etc/profile.d/paseo.sh"
SYSTEMD_UNIT="/etc/systemd/system/paseo.service"

log() {
    printf '[paseo-setup] %s\n' "$*" >&2
}

die() {
    printf '[paseo-setup] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: sudo $(basename "$0")

Reads ${ENV_FILE} when present, then prompts for missing values.

Variables:
  PASEO_USER_PASSWORD       Required Unix password for paseo and sudo.
  PASEO_AUTHORIZED_KEY      Optional single OpenSSH public key for root and paseo.
  PASEO_SSH_PASSWORD_AUTH   auto, true, or false. Default: auto.
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

require_ubuntu() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "This setup supports Ubuntu only."
    [[ -n "${VERSION_CODENAME:-}" ]] || die "Ubuntu VERSION_CODENAME is missing."

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        log "Ubuntu 24.04 is the tested target; continuing on ${PRETTY_NAME:-this Ubuntu release}."
    fi
}

env_mode_is_private() {
    local mode="$1"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 077) == 0 ))
}

validate_env_file_permissions() {
    local env_file="$1"
    local mode

    [[ "${OSTYPE:-}" == linux* ]] || return 0
    mode="$(stat -c '%a' "$env_file")"
    env_mode_is_private "$mode" ||
        die "${env_file} contains a password and must not be accessible by group or other users (run: chmod 600 '${env_file}')."
}

load_env_file() {
    local env_file="$1"
    local line key value
    [[ -f "$env_file" ]] || return 0

    validate_env_file_permissions "$env_file"
    log "Loading ${env_file}."

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^export[[:space:]]+(.+)$ ]]; then
            line="${BASH_REMATCH[1]}"
        fi

        [[ "$line" == *=* ]] || die "Invalid environment line in ${env_file}: ${line}"

        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            die "Invalid environment variable name in ${env_file}: ${key}"

        case "$key" in
            PASEO_USER_PASSWORD|PASEO_AUTHORIZED_KEY|PASEO_SSH_PASSWORD_AUTH)
                ;;
            *)
                die "Unsupported environment variable in ${env_file}: ${key}"
                ;;
        esac

        [[ -v "$key" ]] && continue

        if [[ "$value" == \"*\" && "$value" == *\" && "${#value}" -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' && "${#value}" -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        fi

        printf -v "$key" '%s' "$value"
    done <"$env_file"
}

prompt_password() {
    local first second

    [[ -t 0 ]] || die "PASEO_USER_PASSWORD is required for noninteractive setup."

    while true; do
        read -r -s -p "PASEO_USER_PASSWORD: " first
        printf '\n' >&2
        [[ -n "$first" ]] || {
            log "The password cannot be empty."
            continue
        }

        read -r -s -p "Confirm PASEO_USER_PASSWORD: " second
        printf '\n' >&2
        [[ "$first" == "$second" ]] || {
            log "Passwords do not match."
            continue
        }

        PASEO_USER_PASSWORD="$first"
        return 0
    done
}

resolve_ssh_password_auth() {
    local requested="${1,,}"
    local authorized_key="$2"

    case "$requested" in
        auto)
            [[ -n "$authorized_key" ]] && printf 'no\n' || printf 'yes\n'
            ;;
        true)
            printf 'yes\n'
            ;;
        false)
            printf 'no\n'
            ;;
        *)
            return 1
            ;;
    esac
}

configure_inputs() {
    local entered

    load_env_file "$ENV_FILE"

    [[ -n "${PASEO_USER_PASSWORD:-}" ]] || prompt_password

    if [[ ! -v PASEO_AUTHORIZED_KEY ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Optional PASEO_AUTHORIZED_KEY, Enter to skip: " PASEO_AUTHORIZED_KEY
        else
            PASEO_AUTHORIZED_KEY=""
        fi
    fi

    if [[ -z "${PASEO_SSH_PASSWORD_AUTH:-}" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "PASEO_SSH_PASSWORD_AUTH [auto]: " entered
            PASEO_SSH_PASSWORD_AUTH="${entered:-auto}"
        else
            PASEO_SSH_PASSWORD_AUTH="auto"
        fi
    fi

    PASEO_SSH_PASSWORD_AUTH="${PASEO_SSH_PASSWORD_AUTH,,}"
    resolve_ssh_password_auth "$PASEO_SSH_PASSWORD_AUTH" "$PASEO_AUTHORIZED_KEY" >/dev/null ||
        die "PASEO_SSH_PASSWORD_AUTH must be auto, true, or false."

    export -n PASEO_USER_PASSWORD PASEO_AUTHORIZED_KEY PASEO_SSH_PASSWORD_AUTH 2>/dev/null || true
}

install_apt_repositories() {
    log "Installing package-repository prerequisites."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg

    install -d -m 0755 /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
        gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod 0644 /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$(dpkg --print-architecture)" "$VERSION_CODENAME" \
        >/etc/apt/sources.list.d/docker.list

    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
        gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    chmod 0644 /etc/apt/keyrings/nodesource.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main\n' \
        "$(dpkg --print-architecture)" \
        >/etc/apt/sources.list.d/nodesource.list
}

install_packages() {
    local packages=(
        bash build-essential ca-certificates cmake curl dnsutils fd-find ffmpeg
        file fontconfig fonts-noto-color-emoji fonts-noto-core g++ gnupg git
        imagemagick iproute2 iputils-ping jq less lsof make nano netcat-openbsd
        net-tools nodejs openssh-client openssh-server pipx pkg-config poppler-utils
        procps psmisc python3 python3-pip python3-venv ripgrep rsync shellcheck
        socat sudo tmux tree ufw unzip vim-tiny xz-utils zip
        containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin
    )

    install_apt_repositories
    log "Installing the standalone development toolchain."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
    ln -sf /usr/bin/fdfind /usr/local/bin/fd
    systemctl enable --now docker
}

authorized_key_is_single_line() {
    local key="$1"
    [[ "$key" != *$'\n'* && "$key" != *$'\r'* ]]
}

validate_authorized_key() {
    local key="$1"
    local tmp
    [[ -n "$key" ]] || return 0

    authorized_key_is_single_line "$key" ||
        die "PASEO_AUTHORIZED_KEY must contain exactly one line."

    tmp="$(mktemp)"
    printf '%s\n' "$key" >"$tmp"
    if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "PASEO_AUTHORIZED_KEY is not a valid OpenSSH public key."
    fi
    rm -f "$tmp"
}

configure_user() {
    log "Creating and configuring the ${PASEO_USER} user."

    if id "$PASEO_USER" >/dev/null 2>&1; then
        usermod -s /bin/bash "$PASEO_USER"
    else
        useradd --create-home --home-dir "$PASEO_HOME" --shell /bin/bash "$PASEO_USER"
    fi

    usermod -aG sudo,docker "$PASEO_USER"
    printf '%s:%s\n' "$PASEO_USER" "$PASEO_USER_PASSWORD" | chpasswd
    unset PASEO_USER_PASSWORD

    install -d -m 0755 -o "$PASEO_USER" -g "$PASEO_USER" \
        "$PASEO_HOME" "$PASEO_HOME/.local" "$PASEO_NPM_PREFIX" "$PASEO_WORKSPACE"
    install -d -m 0700 -o "$PASEO_USER" -g "$PASEO_USER" \
        "$PASEO_HOME/.codex" "$PASEO_HOME/.ssh"

    sudo -u "$PASEO_USER" -H npm config set prefix "$PASEO_NPM_PREFIX" --location=user
}

configure_sudo() {
    local tmp
    tmp="$(mktemp)"
    printf '%s ALL=(ALL:ALL) PASSWD: ALL\n' "$PASEO_USER" >"$tmp"
    chmod 0440 "$tmp"
    visudo -cf "$tmp" >/dev/null || {
        rm -f "$tmp"
        die "Generated sudoers configuration is invalid."
    }
    install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
    rm -f "$tmp"
}

append_authorized_key() {
    local user="$1"
    local home_dir="$2"
    local key="$3"
    local group target
    [[ -n "$key" ]] || return 0

    group="$(id -gn "$user")"
    target="${home_dir}/.ssh/authorized_keys"
    install -d -m 0700 -o "$user" -g "$group" "${home_dir}/.ssh"
    touch "$target"
    chown "$user:$group" "$target"
    chmod 0600 "$target"

    grep -qxF -- "$key" "$target" || printf '%s\n' "$key" >>"$target"
}

render_sshd_config() {
    local password_auth="$1"
    cat <<EOF
Match User ${PASEO_USER}
    PubkeyAuthentication yes
    PasswordAuthentication ${password_auth}
    KbdInteractiveAuthentication no
Match all
EOF
}

configure_ssh() {
    local password_auth tmp backup had_existing=false

    grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config ||
        die "/etc/ssh/sshd_config does not include sshd_config.d; refusing to alter the main file."

    append_authorized_key root /root "$PASEO_AUTHORIZED_KEY"
    append_authorized_key "$PASEO_USER" "$PASEO_HOME" "$PASEO_AUTHORIZED_KEY"
    password_auth="$(resolve_ssh_password_auth "$PASEO_SSH_PASSWORD_AUTH" "$PASEO_AUTHORIZED_KEY")"

    install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
    tmp="$(mktemp)"
    backup="$(mktemp)"
    render_sshd_config "$password_auth" >"$tmp"

    if [[ -f "$SSHD_DROP_IN" ]]; then
        cp -a "$SSHD_DROP_IN" "$backup"
        had_existing=true
    fi

    install -m 0644 -o root -g root "$tmp" "$SSHD_DROP_IN"
    if ! /usr/sbin/sshd -t; then
        if [[ "$had_existing" == "true" ]]; then
            cp -a "$backup" "$SSHD_DROP_IN"
        else
            rm -f "$SSHD_DROP_IN"
        fi
        rm -f "$tmp" "$backup"
        die "Generated SSH configuration is invalid; the previous configuration was restored."
    fi

    rm -f "$tmp" "$backup"
    systemctl enable --now ssh
    systemctl reload ssh

    if [[ "$password_auth" == "no" && ! -s "$PASEO_HOME/.ssh/authorized_keys" ]]; then
        log "Password SSH is disabled and paseo has no authorized_keys; root SSH remains unchanged."
    fi
}

configure_docker() {
    local tmp changed=false
    install -d -m 0755 /etc/docker
    tmp="$(mktemp)"

    if [[ -s /etc/docker/daemon.json ]]; then
        jq -e 'type == "object"' /etc/docker/daemon.json >/dev/null ||
            die "/etc/docker/daemon.json must contain a JSON object."
        jq -e '(.["default-network-opts"] // {}) | type == "object"' \
            /etc/docker/daemon.json >/dev/null ||
            die "/etc/docker/daemon.json default-network-opts must be a JSON object."
        jq -e '((.["default-network-opts"] // {}).bridge // {}) | type == "object"' \
            /etc/docker/daemon.json >/dev/null ||
            die "/etc/docker/daemon.json default-network-opts.bridge must be a JSON object."
        jq '
            .ip = "127.0.0.1"
            | .["default-network-opts"].bridge["com.docker.network.bridge.host_binding_ipv4"] = "127.0.0.1"
        ' /etc/docker/daemon.json >"$tmp"
    else
        jq -n '
            {
                "ip": "127.0.0.1",
                "default-network-opts": {
                    "bridge": {
                        "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1"
                    }
                }
            }
        ' >"$tmp"
    fi

    if [[ ! -f /etc/docker/daemon.json ]] || ! cmp -s "$tmp" /etc/docker/daemon.json; then
        install -m 0644 -o root -g root "$tmp" /etc/docker/daemon.json
        changed=true
    fi
    rm -f "$tmp"

    systemctl enable --now docker
    [[ "$changed" == "false" ]] || systemctl restart docker
}

install_npm_tools() {
    if systemctl is-active --quiet paseo 2>/dev/null; then
        log "Stopping Paseo while its system packages are updated."
        systemctl stop paseo
    fi

    log "Installing Paseo, Codex, Claude Code, and Playwright under /usr/local."
    (
        umask 022
        NPM_CONFIG_PREFIX=/usr/local npm install -g \
            @getpaseo/cli \
            @openai/codex \
            @anthropic-ai/claude-code \
            @playwright/test@1.61.0 \
            playwright@1.61.0
    )
    chmod -R a+rX "$SYSTEM_NPM_ROOT"

    install -d -m 0755 "$PLAYWRIGHT_BROWSERS_PATH"
    PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
        /usr/local/bin/playwright install --with-deps
    chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"
    npm cache clean --force >/dev/null 2>&1 || true
}

write_profile_config() {
    cat >"$PROFILE_FILE" <<EOF
if [ "\${USER:-}" = "${PASEO_USER}" ]; then
    export HOME="${PASEO_HOME}"
    export SHELL=/bin/bash
    export CODEX_HOME="${PASEO_HOME}/.codex"
    export NPM_CONFIG_PREFIX="${PASEO_NPM_PREFIX}"
    export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}"
    export NODE_PATH="${PASEO_NPM_PREFIX}/lib/node_modules:${SYSTEM_NPM_ROOT}"
    export DISABLE_AUTOUPDATER=1
    PATH="${PASEO_HOME}/.local/bin:${PASEO_NPM_PREFIX}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export PATH
fi
EOF
    chown root:root "$PROFILE_FILE"
    chmod 0644 "$PROFILE_FILE"
}

render_systemd_unit() {
    cat <<EOF
[Unit]
Description=Paseo coding-agent daemon
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=${PASEO_USER}
Group=${PASEO_USER}
SupplementaryGroups=docker
WorkingDirectory=${PASEO_WORKSPACE}
Environment=HOME=${PASEO_HOME}
Environment=USER=${PASEO_USER}
Environment=SHELL=/bin/bash
Environment=CODEX_HOME=${PASEO_HOME}/.codex
Environment=NPM_CONFIG_PREFIX=${PASEO_NPM_PREFIX}
Environment=PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}
Environment=NODE_PATH=${PASEO_NPM_PREFIX}/lib/node_modules:${SYSTEM_NPM_ROOT}
Environment=DISABLE_AUTOUPDATER=1
Environment=PATH=${PASEO_HOME}/.local/bin:${PASEO_NPM_PREFIX}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/paseo daemon start --foreground --listen 127.0.0.1:6767 --no-web-ui
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
}

install_systemd_service() {
    local tmp
    tmp="$(mktemp --suffix=.service)"
    render_systemd_unit >"$tmp"
    systemd-analyze verify "$tmp"
    install -m 0644 -o root -g root "$tmp" "$SYSTEMD_UNIT"
    rm -f "$tmp"

    systemctl daemon-reload
    systemctl enable --now paseo
}

ssh_server_port_from_connection() {
    local connection="$1"
    local port
    local -a fields

    read -r -a fields <<<"$connection"
    [[ "${#fields[@]}" -eq 4 ]] || return 1
    port="${fields[3]}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    printf '%s\n' "$port"
}

configure_firewall() {
    local current_ssh_port=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        current_ssh_port="$(ssh_server_port_from_connection "$SSH_CONNECTION")" ||
            die "Cannot determine the active SSH server port from SSH_CONNECTION; UFW was not changed."
    fi

    log "Enabling UFW with SSH allowed on port 22."
    ufw allow 22/tcp >/dev/null
    if [[ -n "$current_ssh_port" && "$current_ssh_port" != "22" ]]; then
        log "Also allowing the active SSH server port ${current_ssh_port} to preserve this session."
        ufw allow "${current_ssh_port}/tcp" >/dev/null
    fi
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
}

run_as_paseo() {
    sudo -u "$PASEO_USER" -H env \
        HOME="$PASEO_HOME" \
        USER="$PASEO_USER" \
        SHELL=/bin/bash \
        CODEX_HOME="$PASEO_HOME/.codex" \
        NPM_CONFIG_PREFIX="$PASEO_NPM_PREFIX" \
        PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH" \
        NODE_PATH="$PASEO_NPM_PREFIX/lib/node_modules:$SYSTEM_NPM_ROOT" \
        DISABLE_AUTOUPDATER=1 \
        PATH="$PASEO_HOME/.local/bin:$PASEO_NPM_PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$@"
}

verify_setup() {
    local listen_output

    log "Verifying the installation."
    visudo -cf "$SUDOERS_FILE" >/dev/null
    /usr/sbin/sshd -t
    systemd-analyze verify "$SYSTEMD_UNIT"
    jq -e '
        .ip == "127.0.0.1"
        and .["default-network-opts"].bridge["com.docker.network.bridge.host_binding_ipv4"] == "127.0.0.1"
    ' /etc/docker/daemon.json >/dev/null
    id -nG "$PASEO_USER" | tr ' ' '\n' | grep -qx sudo
    id -nG "$PASEO_USER" | tr ' ' '\n' | grep -qx docker
    ufw status | grep -Eq '^22/tcp[[:space:]]+ALLOW'

    run_as_paseo /usr/local/bin/paseo --version
    run_as_paseo /usr/local/bin/codex --version
    run_as_paseo /usr/local/bin/claude --version
    run_as_paseo /usr/local/bin/playwright --version
    run_as_paseo docker info >/dev/null
    run_as_paseo node -e '
        const { chromium } = require("playwright");
        (async () => {
            const browser = await chromium.launch({ headless: true });
            const page = await browser.newPage();
            await page.setContent("<title>Paseo Playwright check</title>");
            if ((await page.title()) !== "Paseo Playwright check") process.exitCode = 1;
            await browser.close();
        })().catch((error) => { console.error(error); process.exit(1); });
    '

    systemctl is-active --quiet paseo
    for _ in {1..30}; do
        curl -fsS http://127.0.0.1:6767/api/health >/dev/null && break
        sleep 1
    done
    curl -fsS http://127.0.0.1:6767/api/health >/dev/null || {
        journalctl -u paseo --no-pager -n 50 >&2 || true
        die "Paseo did not become healthy on 127.0.0.1:6767."
    }

    listen_output="$(ss -ltnH)"
    grep -Eq '127\.0\.0\.1:6767[[:space:]]' <<<"$listen_output" ||
        die "Paseo is not listening on 127.0.0.1:6767."
    if grep -Eq '(0\.0\.0\.0|\*|\[::\]):6767[[:space:]]' <<<"$listen_output"; then
        die "Paseo is listening publicly on port 6767."
    fi
}

main() {
    case "${1:-}" in
        -h|--help|help)
            usage
            return 0
            ;;
        "")
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac

    require_root
    require_ubuntu
    configure_inputs
    install_packages
    validate_authorized_key "$PASEO_AUTHORIZED_KEY"
    configure_user
    configure_sudo
    configure_ssh
    configure_docker
    install_npm_tools
    write_profile_config
    configure_firewall
    install_systemd_service
    verify_setup

    log "Setup complete. Pair a client with: sudo -u paseo -H paseo daemon pair --json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
