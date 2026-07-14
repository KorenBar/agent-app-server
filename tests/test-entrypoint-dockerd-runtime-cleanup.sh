#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
entrypoint="${repo_root}/agent-app/entrypoint.sh"

dockerd_command="$(
    awk '
        /^\[program:dockerd\]$/ { in_dockerd = 1; next }
        /^\[/ { in_dockerd = 0 }
        in_dockerd && /^command=/ { print; exit }
    ' "$entrypoint"
)"

if [[ -z "$dockerd_command" ]]; then
    printf 'Missing supervisord dockerd command in %s\n' "$entrypoint" >&2
    exit 1
fi

for runtime_file in /var/run/docker.pid /var/run/docker.sock; do
    if [[ "$dockerd_command" != *"rm -f"* || "$dockerd_command" != *"$runtime_file"* ]]; then
        printf 'dockerd command must remove stale %s before starting.\n' "$runtime_file" >&2
        printf 'Actual command: %s\n' "$dockerd_command" >&2
        exit 1
    fi
done

if [[ "$dockerd_command" != *"exec /usr/bin/dockerd"* ]]; then
    printf 'dockerd command should exec dockerd after cleanup.\n' >&2
    printf 'Actual command: %s\n' "$dockerd_command" >&2
    exit 1
fi
