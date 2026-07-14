#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${repo_root}/agent-app/compose.yaml"

python3 - "$compose_file" <<'PY'
import pathlib
import sys

import yaml

compose = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
volumes = compose["services"]["agent-app"]["volumes"]

required = "../volumes/agent-app/home:/home/agent"
if required not in volumes:
    raise SystemExit(f"missing whole-home volume mount: {required}")

disallowed_targets = {
    "/home/agent/.codex",
    "/home/agent/Documents",
    "/home/agent/.local",
    "/home/agent/.npm-global",
}

for volume in volumes:
    parts = volume.split(":")
    if len(parts) >= 2 and parts[1] in disallowed_targets:
        raise SystemExit(f"home subdirectory should not be mounted separately: {volume}")
PY
