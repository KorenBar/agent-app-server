# Agent App Server

Self-hosted browser access to Codex with SSH, Docker-in-Docker, HTTPS,
wildcard port routing, and single-user Authelia two-factor authentication.

This server root is meant to be deployed on a fresh Ubuntu VPS, preferably
Ubuntu 24.04 or newer. It is best installed on a dedicated VPS with no unrelated
services, because the Agent App container is privileged so it can run inner
Docker and support development workflows.

## Requirements

Recommended server:

```text
OS:      Ubuntu 24.04 or newer
CPU:     1 vCPU minimum
RAM:     1GB minimum, 2GB+ preferred
Disk:    25GB minimum, 32GB recommended, 50GB+ comfortable
```

The 25GB minimum assumes a dedicated server and occasional Docker cleanup after
repeated builds or upgrades. Use 32GB or more for a smoother first deployment,
and 50GB or more if you expect large workspaces, browser automation, or many
inner Docker images.

## Quick Install

This command downloads the current `main` branch from
`KorenBar/agent-app-server` and runs setup:

```bash
sudo mkdir -p /opt/servers && curl -fsSL https://github.com/KorenBar/agent-app-server/archive/refs/heads/main.tar.gz | sudo tar -xz --strip-components=1 -C /opt/servers && cd /opt/servers && sudo ./setup-agent-app.sh
```

For a stable production install, prefer a tagged release once releases exist by
replacing `refs/heads/main` with `refs/tags/vX.Y.Z`.

You can predefine values before the same one-line setup command. Missing values
will be asked interactively:

```bash
sudo mkdir -p /opt/servers && curl -fsSL https://github.com/KorenBar/agent-app-server/archive/refs/heads/main.tar.gz | sudo tar -xz --strip-components=1 -C /opt/servers && cd /opt/servers && sudo AGENT_APP_DOMAIN=agent.example.com ADMIN_EMAIL=admin@example.com AGENT_APP_AUTH_USERNAME=agent AGENT_APP_AUTH_PASSWORD='replace-with-a-long-secret' ACME_DNS_DOMAIN=authdns.example.com ./setup-agent-app.sh
```

The setup script installs or updates Docker, starts the public reverse proxy,
configures UFW, generates Authelia config, registers ACME DNS validation, prints
the DNS records to create, waits for confirmation, then starts Agent App.

## Values To Prepare

The setup script reads `/opt/servers/public-edge/.env` and
`/opt/servers/agent-app/.env` if they exist. It asks for missing values, but it
does not write your answers back to `.env`.

| Variable | Required | Purpose |
|---|---:|---|
| `AGENT_APP_DOMAIN` | yes | Public domain for the Agent App UI, for example `agent.example.com`. |
| `ADMIN_EMAIL` | yes | Email used for Let's Encrypt and the Authelia user. |
| `ACME_DNS_DOMAIN` | yes | Delegated DNS-01 zone, for example `authdns.example.com`. |
| `AGENT_APP_AUTH_USERNAME` | yes | Single Authelia login username. |
| `AGENT_APP_AUTH_PASSWORD` | yes | Single Authelia login password. |
| `AGENT_APP_AUTH_DOMAIN` | optional | Login domain. Defaults to `auth.${AGENT_APP_DOMAIN}`. |
| `AGENT_APP_ENABLE_SMTP` | optional | `auto`, `true`, or `false`. Auto enables SMTP only if outbound TCP/25 works. |
| `AGENT_APP_SMTP_DOMAIN` | optional | Send-only mail domain when SMTP is enabled. Defaults to `AGENT_APP_DOMAIN`. |
| `AGENT_APP_SSH_PORT` | optional | Host SSH port for the `agent` user. Defaults to `2222`. |
| `AGENT_APP_SSH_BIND` | optional | SSH bind address. Defaults to `0.0.0.0` when SSH UFW opening is enabled, otherwise `127.0.0.1`. |
| `OPEN_AGENT_APP_SSH_PORT` | optional | Whether setup opens the Agent App SSH port in UFW. Defaults to `true`. |
| `AGENT_APP_AUTHORIZED_KEYS` | optional | SSH public key for the `agent` user. |
| `AGENT_APP_PASSWORD` | optional | Enables SSH password login for the `agent` user. Key login is preferred. |
| `TZ` | optional | Container timezone. Defaults to `Asia/Jerusalem`. |

Advanced values such as `ACME_DNS_NSNAME`, `ACME_DNS_NSADMIN`,
`ACME_DNS_BIND_IP`, `CODEXUI_SANDBOX_MODE`, `CODEXUI_APPROVAL_POLICY`, and
`AGENT_APP_ENABLE_SUDO` are documented in the deeper service READMEs.

## DNS And Firewalls

The setup script prints the DNS table you need to create in your DNS manager.
It includes the Agent App domain, auth domain, wildcard port domain, ACME DNS
delegation, and email records when local SMTP is enabled.

The script configures UFW on the Ubuntu server. If your VPS provider also has
an external firewall, open these ports there too:

```text
22/tcp                         server administration SSH
80/tcp                         HTTP validation and redirect
443/tcp                        HTTPS access
53/tcp and 53/udp              acme-dns authoritative DNS
AGENT_APP_SSH_PORT/tcp         optional direct SSH to the agent container
```

Do not open every development port publicly. Ports `1024` through `65535` are
reached securely through HTTPS wildcard domains instead.

## First Login And Codes

Open:

```text
https://<your-agent-domain>
```

Authelia will redirect you to the login page. On the first successful password
login, it asks you to register a TOTP authenticator app with a QR code.

Authelia needs to send a one-time code during setup and recovery flows:

- If outbound TCP/25 is open, setup enables a local send-only SMTP container and
  sends mail from your configured domain.
- If outbound TCP/25 is blocked, setup uses file notifications instead. The
  code is written to a volume file and also printed by the notification watcher
  container.

When SMTP is disabled, follow the notification logs before first login:

```bash
sudo docker logs -f agent-app-notifications
```

Or read the file directly:

```bash
sudo tail -n +1 -F /opt/servers/volumes/agent-app/authelia/config/notification.txt
```

Copy the one-time code from there. This is normally needed only once for first
TOTP registration, unless you later use Authelia reset or recovery flows.

## Features

- Authelia protects all public pages with login and two-factor authentication.
- Agent App UI is available at `https://<your-agent-domain>`.
- Development ports `1024-65535` are available as
  `https://<port>.<your-agent-domain>` after authentication and with automatic
  TLS certificates.
- A dev server listening inside the Agent App container on port `<port>` is
  reached remotely as `https://<port>.<your-agent-domain>`. Bind dev servers to
  `0.0.0.0`, not only `127.0.0.1`, so nginx can reach them from its container.
- The container includes `@openai/codex`, `codexapp`, SSH, browser-ready
  Playwright dependencies, common developer tools, and inner Docker.
- Workspace files live in `/opt/servers/volumes/agent-app/workspace`.
- Persistent user state lives under `/opt/servers/volumes/agent-app`.

The installed `codexapp` web UI is based on the Codex UI project:
https://github.com/friuns2/codexui

## Recovery

Forgot the Authelia username:

```bash
sudo sed -n '1,80p' /opt/servers/volumes/agent-app/authelia/config/users_database.yml
```

Forgot the password: rerun setup with the same username and a new
`AGENT_APP_AUTH_PASSWORD`; setup rewrites the password hash.

Lost the authenticator app: stop Authelia and remove its SQLite database. The
next login will enroll TOTP again.

```bash
cd /opt/servers/agent-app
sudo docker compose stop agent-app-authelia
sudo rm -f /opt/servers/volumes/agent-app/authelia/config/db.sqlite3
sudo docker compose up -d agent-app-authelia
```

## Logs

Agent App stack:

```bash
sudo docker compose -f /opt/servers/agent-app/compose.yaml logs -f --tail=200
```

Public edge stack:

```bash
sudo docker compose -f /opt/servers/public-edge/compose.yaml logs -f --tail=200
```

All running containers, one snapshot:

```bash
sudo sh -c 'for c in $(docker ps --format "{{.Names}}"); do echo "===== $c ====="; docker logs --tail=100 "$c"; done'
```

## Backups

Back up the whole volumes directory:

```text
/opt/servers/volumes
```

It contains workspace files, Codex/Agent App state, Authelia database and
secrets, ACME credentials, SSH keys, SMTP DKIM keys, and Docker state. Use
Restic, Borg, or another encrypted backup tool, and protect the backup like a
password.

## More Details

- `agent-app/README.md` explains the Agent App container, Authelia, dynamic
  port routing, SSH, inner Docker, and volume layout.
- `public-edge/README.md` explains nginx-proxy, acme-companion, acme-dns,
  DNS-01 delegation, and shared edge operations.
