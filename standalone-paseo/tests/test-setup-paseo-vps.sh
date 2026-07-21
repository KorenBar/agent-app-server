#!/usr/bin/env bash

set -Eeuo pipefail

standalone_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
setup_script="${standalone_dir}/setup-paseo-vps.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# shellcheck disable=SC1090,SC1091
source "$setup_script"

env_file="$tmp_dir/.env"
sentinel="$tmp_dir/should-not-exist"

cat >"$env_file" <<EOF
PASEO_USER_PASSWORD="from file"
PASEO_AUTHORIZED_KEY=\$(touch "$sentinel")
PASEO_SSH_PASSWORD_AUTH=auto
EOF

export PASEO_USER_PASSWORD="from process"
unset PASEO_AUTHORIZED_KEY PASEO_SSH_PASSWORD_AUTH
load_env_file "$env_file"
expected_key="\$(touch \"$sentinel\")"

[[ "$PASEO_USER_PASSWORD" == "from process" ]]
[[ "$PASEO_AUTHORIZED_KEY" == "$expected_key" ]]
[[ "$PASEO_SSH_PASSWORD_AUTH" == "auto" ]]
[[ ! -e "$sentinel" ]]

unsupported_env="$tmp_dir/unsupported.env"
printf 'PATH=/tmp/untrusted\n' >"$unsupported_env"
if (load_env_file "$unsupported_env") >/dev/null 2>&1; then
    exit 1
fi

env_mode_is_private 600
env_mode_is_private 0400
if env_mode_is_private 640; then
    exit 1
fi
if env_mode_is_private 606; then
    exit 1
fi

if (
    # configure_inputs reads this sourced-script global.
    # shellcheck disable=SC2034
    ENV_FILE="$tmp_dir/missing.env"
    unset PASEO_USER_PASSWORD PASEO_AUTHORIZED_KEY PASEO_SSH_PASSWORD_AUTH
    configure_inputs </dev/null
) >/dev/null 2>&1; then
    exit 1
fi

authorized_key_is_single_line 'ssh-ed25519 AAAA comment'
if authorized_key_is_single_line $'first key\nsecond key'; then
    exit 1
fi

[[ "$(resolve_ssh_password_auth auto "")" == "yes" ]]
[[ "$(resolve_ssh_password_auth auto "$PASEO_AUTHORIZED_KEY")" == "no" ]]
[[ "$(resolve_ssh_password_auth true "")" == "yes" ]]
[[ "$(resolve_ssh_password_auth false "$PASEO_AUTHORIZED_KEY")" == "no" ]]
if resolve_ssh_password_auth invalid "" >/dev/null 2>&1; then
    exit 1
fi

[[ "$(ssh_server_port_from_connection '192.0.2.10 50000 203.0.113.20 2222')" == "2222" ]]
if ssh_server_port_from_connection 'invalid connection' >/dev/null 2>&1; then
    exit 1
fi

ssh_config="$tmp_dir/00-paseo.conf"
render_sshd_config no >"$ssh_config"
grep -qx 'Match User paseo' "$ssh_config"
grep -qx '    PubkeyAuthentication yes' "$ssh_config"
grep -qx '    PasswordAuthentication no' "$ssh_config"
grep -qx '    KbdInteractiveAuthentication no' "$ssh_config"
grep -qx 'Match all' "$ssh_config"
if grep -q 'PermitRootLogin' "$ssh_config"; then
    exit 1
fi

service_unit="$tmp_dir/paseo.service"
render_systemd_unit >"$service_unit"
grep -qx 'User=paseo' "$service_unit"
grep -qx 'SupplementaryGroups=docker' "$service_unit"
grep -qx 'WorkingDirectory=/workspace' "$service_unit"
grep -qx 'Environment=PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright' "$service_unit"
grep -qx 'Environment=NODE_PATH=/home/paseo/.npm-global/lib/node_modules:/usr/local/lib/node_modules' "$service_unit"
grep -qx 'ExecStart=/usr/local/bin/paseo daemon start --foreground --listen 127.0.0.1:6767 --no-web-ui' "$service_unit"

grep -Fq '.["default-network-opts"].bridge["com.docker.network.bridge.host_binding_ipv4"] = "127.0.0.1"' "$setup_script"
grep -Fq '/run/sshd' "$setup_script"

printf 'standalone Paseo setup tests passed\n'
