#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

env_file="$tmp_dir/.env"

cat >"$env_file" <<'EOF'
# Normal dotenv syntax should not execute shell commands.
export ADMIN_EMAIL=admin@example.com
AGENT_APP_AUTHORIZED_KEYS=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKsh9Mo0Z1FqRGWGuQhLrOcX9DONj6tZbG4Fssb8EpKr user@example
AGENT_APP_PASSWORD="secret with spaces"
AGENT_APP_AUTH_USERNAME='agent user'
EOF

(
    source "$repo_root/setup-agent-app.sh"
    load_env_file "$env_file"

    [[ "${ADMIN_EMAIL}" == "admin@example.com" ]]
    [[ "${AGENT_APP_AUTHORIZED_KEYS}" == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKsh9Mo0Z1FqRGWGuQhLrOcX9DONj6tZbG4Fssb8EpKr user@example" ]]
    [[ "${AGENT_APP_PASSWORD}" == "secret with spaces" ]]
    [[ "${AGENT_APP_AUTH_USERNAME}" == "agent user" ]]
)
