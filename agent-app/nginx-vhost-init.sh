#!/usr/bin/env bash
set -euo pipefail

log() {
    printf '[agent-app-nginx-vhost] %s\n' "$*" >&2
}

domain="${AGENT_APP_DOMAIN:?AGENT_APP_DOMAIN is missing}"
auth_domain="${AGENT_APP_AUTH_DOMAIN:?AGENT_APP_AUTH_DOMAIN is missing}"
vhost_dir="${NGINX_VHOST_DIR:-/etc/nginx/vhost.d}"
port_pattern='(?:102[4-9]|10[3-9][0-9]|1[1-9][0-9]{2}|[2-9][0-9]{3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])'
marker='# agent-app nginx-proxy config generated'
old_marker='# agent-app dynamic port proxy generated'

if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
    log "invalid AGENT_APP_DOMAIN: ${domain}"
    exit 1
fi

if [[ ! "$auth_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
    log "invalid AGENT_APP_AUTH_DOMAIN: ${auth_domain}"
    exit 1
fi

mkdir -p "$vhost_dir"

find "$vhost_dir" -maxdepth 1 -type f -exec sh -c '
    marker="$1"
    old_marker="$2"
    shift
    shift
    for path do
        first_line="$(head -n 1 "$path" 2>/dev/null || true)"
        if [ "$first_line" = "$marker" ] || [ "$first_line" = "$old_marker" ]; then
            rm -f "$path"
        fi
    done
' sh "$marker" "$old_marker" {} +

domain_regex="${domain//./\\.}"

write_file() {
    local target="$1"
    local tmp

    tmp="$(mktemp "${target}.tmp.XXXXXX")"
    cat >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$target"
    log "wrote ${target}"
}

write_file "${vhost_dir}/${domain}" <<EOF
${marker}
location = /internal/authelia/authz {
    internal;

    proxy_pass http://agent-app-authelia:9091/api/authz/auth-request;
    proxy_http_version 1.1;
    proxy_pass_request_body off;

    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
    proxy_set_header Cookie \$http_cookie;
    proxy_set_header Host \$host;
    proxy_set_header X-Original-Method \$request_method;
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Method \$request_method;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Uri \$request_uri;
    proxy_set_header X-Real-IP \$remote_addr;
}
EOF

write_file "${vhost_dir}/*.${domain}" <<EOF
${marker}
location = /internal/authelia/authz {
    internal;

    proxy_pass http://agent-app-authelia:9091/api/authz/auth-request;
    proxy_http_version 1.1;
    proxy_pass_request_body off;

    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
    proxy_set_header Cookie \$http_cookie;
    proxy_set_header Host \$host;
    proxy_set_header X-Original-Method \$request_method;
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Method \$request_method;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Uri \$request_uri;
    proxy_set_header X-Real-IP \$remote_addr;
}
EOF

auth_request_snippet="$(cat <<'EOF'
    auth_request /internal/authelia/authz;
    auth_request_set $auth_redirect $upstream_http_location;
    auth_request_set $auth_user $upstream_http_remote_user;
    auth_request_set $auth_groups $upstream_http_remote_groups;
    auth_request_set $auth_email $upstream_http_remote_email;
    auth_request_set $auth_name $upstream_http_remote_name;

    proxy_set_header Remote-User $auth_user;
    proxy_set_header Remote-Groups $auth_groups;
    proxy_set_header Remote-Email $auth_email;
    proxy_set_header Remote-Name $auth_name;

    error_page 401 =302 $auth_redirect;
EOF
)"

write_file "${vhost_dir}/${domain}_location" <<EOF
${marker}
${auth_request_snippet}
EOF

write_file "${vhost_dir}/*.${domain}_location_override" <<EOF
${marker}
location / {
    if (\$scheme = http) {
        return 301 https://\$host\$request_uri;
    }

${auth_request_snippet}

    set \$agent_app_dynamic_port "";

    if (\$host ~* "^(${port_pattern})\\.${domain_regex}$") {
        set \$agent_app_dynamic_port \$1;
    }

    if (\$agent_app_dynamic_port = "") {
        return 404;
    }

    resolver 127.0.0.11 valid=30s ipv6=off;

    proxy_pass http://agent-app:\$agent_app_dynamic_port;
    proxy_http_version 1.1;

    proxy_set_header Host \$host\$host_port;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$proxy_connection;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_x_forwarded_for;
    proxy_set_header X-Forwarded-Host \$proxy_x_forwarded_host;
    proxy_set_header X-Forwarded-Proto \$proxy_x_forwarded_proto;
    proxy_set_header X-Forwarded-Ssl \$proxy_x_forwarded_ssl;
    proxy_set_header X-Forwarded-Port \$proxy_x_forwarded_port;
    proxy_set_header X-Original-URI \$request_uri;
    proxy_set_header Proxy "";

    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
EOF
