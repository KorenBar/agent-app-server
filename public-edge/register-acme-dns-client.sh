#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CREDENTIAL_DIR="$SERVER_ROOT/volumes/acme-dns/clients"
API_URL="${ACME_DNS_API_URL:-http://127.0.0.1:8080}"

die() {
    printf '[acme-dns-register] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage:
  sudo $(basename "$0") <service-name> <namecheap-cname-host>

Example:
  sudo $(basename "$0") app-example _acme-challenge.app
EOF
}

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo or as root."
[[ "$#" -eq 2 ]] || {
    usage >&2
    exit 1
}

service_name="$1"
cname_host="$2"
credential_file="$CREDENTIAL_DIR/${service_name}.env"
registration_file="$CREDENTIAL_DIR/${service_name}.registration.json"

[[ "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ||
    die "Service name may contain only letters, digits, underscore, and hyphen."
[[ ! -e "$credential_file" && ! -e "$registration_file" ]] ||
    die "Registration already exists for ${service_name}; refusing to replace its credentials."

mkdir -p "$CREDENTIAL_DIR"

response="$(curl -fsS -X POST "$API_URL/register")" ||
    die "Unable to reach acme-dns registration API at ${API_URL}. Start public-edge first."

username="$(printf '%s' "$response" | sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
password="$(printf '%s' "$response" | sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
subdomain="$(printf '%s' "$response" | sed -n 's/.*"subdomain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fulldomain="$(printf '%s' "$response" | sed -n 's/.*"fulldomain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

[[ -n "$username" && -n "$password" && -n "$subdomain" && -n "$fulldomain" ]] ||
    die "acme-dns returned an unexpected registration response."

printf '%s\n' "$response" >"$registration_file"
printf 'ACMESH_DNS_API_CONFIG={"DNS_API":"dns_acmedns","ACMEDNS_BASE_URL":"http://acme-dns:8080","ACMEDNS_USERNAME":"%s","ACMEDNS_PASSWORD":"%s","ACMEDNS_SUBDOMAIN":"%s"}\n' \
    "$username" "$password" "$subdomain" >"$credential_file"

cat <<EOF
[acme-dns-register] Created credentials for ${service_name}.
[acme-dns-register] Saved private Compose environment file:
  ${credential_file}

Create this permanent CNAME record at Namecheap:
  Host:  ${cname_host}
  Value: ${fulldomain}.

After DNS propagates, start or recreate ${service_name}.
EOF
