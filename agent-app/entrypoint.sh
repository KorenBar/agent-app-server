#!/usr/bin/env bash

set -Eeuo pipefail

user="agent"
home_dir="/home/${user}"
ssh_input_dir="/opt/agent-app/ssh"
authorized_keys_file="${ssh_input_dir}/authorized_keys"
persistent_ssh_dir="/etc/ssh/persistent"
supervisor_config="/etc/supervisor/supervisord.conf"
user_path="${home_dir}/.local/bin:/usr/local/sbin:/usr/local/bin:${home_dir}/.npm-global/bin:/usr/sbin:/usr/bin:/sbin:/bin"
codexui_sandbox_mode="${CODEXUI_SANDBOX_MODE:-danger-full-access}"
codexui_approval_policy="${CODEXUI_APPROVAL_POLICY:-never}"
sudoers_file="/etc/sudoers.d/${user}"
docker_host="${DOCKER_HOST:-unix:///var/run/docker.sock}"

log() {
    printf '[agent-app-entrypoint] %s\n' "$*" >&2
}

ensure_host_key() {
    local type="$1"
    local path="$persistent_ssh_dir/ssh_host_${type}_key"

    if [[ ! -s "$path" ]]; then
        log "Generating persistent ${type} SSH host key."
        ssh-keygen -q -N "" -t "$type" -f "$path"
    fi

    if [[ ! -s "$path.pub" ]]; then
        ssh-keygen -y -f "$path" >"$path.pub"
    fi

    chown root:root "$path" "$path.pub"
    chmod 0600 "$path"
    chmod 0644 "$path.pub"
}

prepare_host_keys() {
    install -d -m 0700 "$persistent_ssh_dir"
    ensure_host_key ed25519
    ensure_host_key ecdsa
    ensure_host_key rsa
}

prepare_authorized_keys() {
    local ssh_dir="$home_dir/.ssh"
    local target="$ssh_dir/authorized_keys"
    local tmp

    install -d -m 0700 -o "$user" -g "$user" "$ssh_dir"
    tmp="$(mktemp)"

    if [[ -n "${AGENT_APP_AUTHORIZED_KEYS:-}" ]]; then
        printf '%s\n' "$AGENT_APP_AUTHORIZED_KEYS" >>"$tmp"
    fi

    if [[ -f "$authorized_keys_file" ]]; then
        cat "$authorized_keys_file" >>"$tmp"
    fi

    if [[ -s "$tmp" ]]; then
        install -m 0600 -o "$user" -g "$user" "$tmp" "$target"
        log "Installed SSH authorized_keys for ${user}."
    else
        rm -f "$target"
        log "No SSH public key configured."
    fi

    rm -f "$tmp"
}

configure_password_auth() {
    if [[ -n "${AGENT_APP_PASSWORD:-}" ]]; then
        printf '%s:%s\n' "$user" "$AGENT_APP_PASSWORD" | chpasswd
        printf '%s\n' "yes"
        log "Password SSH login is enabled for ${user}."
    else
        passwd -l "$user" >/dev/null 2>&1 || true
        printf '%s\n' "no"
        log "Password SSH login is disabled."
    fi
}

configure_sudo_access() {
    case "${AGENT_APP_ENABLE_SUDO:-false}" in
        true|TRUE|True|1|yes|YES|Yes)
            printf '%s\n' "${user} ALL=(ALL) NOPASSWD:ALL" >"$sudoers_file"
            chown root:root "$sudoers_file"
            chmod 0440 "$sudoers_file"
            log "Passwordless sudo is enabled for ${user}."
            ;;
        *)
            rm -f "$sudoers_file"
            log "Passwordless sudo is disabled for ${user}."
            ;;
    esac
}

write_sshd_config() {
    local password_auth="$1"

    cat >/etc/ssh/sshd_config <<EOF
Port 22
ListenAddress 0.0.0.0
Protocol 2

HostKey ${persistent_ssh_dir}/ssh_host_ed25519_key
HostKey ${persistent_ssh_dir}/ssh_host_ecdsa_key
HostKey ${persistent_ssh_dir}/ssh_host_rsa_key

PermitRootLogin no
AllowUsers ${user}
PubkeyAuthentication yes
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 120
ClientAliveCountMax 2
PrintMotd no

Subsystem sftp /usr/lib/openssh/sftp-server
AcceptEnv LANG LC_*
EOF
}

write_supervisor_config() {
    install -d -m 0755 /var/log/supervisor /etc/supervisor

    cat >"$supervisor_config" <<EOF
[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:sshd]
command=/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
priority=10
autostart=true
autorestart=true
startsecs=2
startretries=10
stopsignal=TERM
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true

[program:dockerd]
command=/bin/bash -lc 'rm -f /var/run/docker.pid /var/run/docker.sock /run/docker.pid /run/docker.sock; exec /usr/bin/dockerd --host=unix:///var/run/docker.sock --data-root=/var/lib/docker --storage-driver=overlay2 --bip=10.200.0.1/24 --default-address-pool base=10.201.0.0/16,size=24'
priority=15
autostart=true
autorestart=true
startsecs=5
startretries=10
stopsignal=TERM
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true

[program:codexapp]
command=/bin/bash -lc 'cd /workspace && exec codexapp /workspace --no-tunnel --no-login --no-open --no-password -p 5900 --sandbox-mode "\${CODEXUI_SANDBOX_MODE}" --approval-policy "\${CODEXUI_APPROVAL_POLICY}"'
user=${user}
environment=HOME="${home_dir}",USER="${user}",SHELL="/bin/bash",CODEX_HOME="${home_dir}/.codex",NPM_CONFIG_PREFIX="${home_dir}/.npm-global",CODEXUI_SANDBOX_MODE="${codexui_sandbox_mode}",CODEXUI_APPROVAL_POLICY="${codexui_approval_policy}",DOCKER_HOST="${docker_host}",DOCKER_BUILDKIT="1",COMPOSE_DOCKER_CLI_BUILD="1",PATH="${user_path}"
priority=20
autostart=true
autorestart=true
startsecs=5
startretries=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF
}

write_profile_config() {
    cat >/etc/profile.d/agent-app.sh <<'EOF'
export CODEX_HOME=/home/agent/.codex
export NPM_CONFIG_PREFIX=/home/agent/.npm-global
export SHELL=/bin/bash
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
PATH="/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/home/agent/.npm-global/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

if [ "${USER:-}" = "agent" ] && [ -d /workspace ]; then
    cd /workspace || true
fi
EOF
}

prepare_runtime_dirs() {
    local home_state_dirs=(
        "$home_dir/.codex"
        "$home_dir/Documents"
        "$home_dir/.local"
        "$home_dir/.npm-global"
    )

    install -d -m 0755 /run/sshd /workspace /var/lib/docker
    install -d -m 0700 -o "$user" -g "$user" "$home_dir/.codex"
    install -d -m 0755 -o "$user" -g "$user" "$home_dir/Documents" "$home_dir/.local" "$home_dir/.npm-global"
    chown "$user:$user" /workspace "$home_dir"

    if ! chown -R "$user:$user" "${home_state_dirs[@]}"; then
        log "Could not fix ownership of one or more persisted home directories."
        return 1
    fi
}

main() {
    local password_auth

    prepare_runtime_dirs
    prepare_host_keys
    prepare_authorized_keys
    password_auth="$(configure_password_auth)"
    configure_sudo_access
    write_sshd_config "$password_auth"
    write_profile_config
    write_supervisor_config

    if [[ "$password_auth" == "no" && ! -s "$home_dir/.ssh/authorized_keys" ]]; then
        log "SSH is running, but no login method is configured."
    fi

    log "Starting sshd and Agent App..."

    exec "$@"
}

main "$@"
