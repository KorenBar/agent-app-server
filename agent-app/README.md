# Agent App Deployment

This service builds a local image with Node.js, OpenSSH, `@openai/codex`, and `codexapp` installed globally.

The container runs two supervised processes:

- `sshd` on container port `22`
- `SHELL=/bin/bash node /usr/local/bin/codexapp /workspace --no-tunnel --no-login --no-open --no-password -p 5900 --sandbox-mode ${CODEXUI_SANDBOX_MODE} --approval-policy ${CODEXUI_APPROVAL_POLICY}`

The compose stack also runs an Authelia container as the public access gate for
`${AGENT_APP_DOMAIN}` and `*.${AGENT_APP_DOMAIN}`.

`supervisord` restarts either child process if it exits. The Docker
healthcheck verifies that `sshd` is running and that the Agent App port accepts
connections; with the shared `autoheal` service, an unhealthy container is
restarted automatically.

## Start

Recommended setup from the shared server root:

```bash
cd /opt/servers
sudo ./setup-agent-app.sh -d
```

The setup script expects the shared `public-edge` overlay to be present at
`/opt/servers/public-edge`.

The setup script:

- loads `/opt/servers/public-edge/.env` and `/opt/servers/agent-app/.env` if they exist
- prompts for missing required values first
- prompts for optional values and skips them when left empty
- keeps newly entered values only for that setup run and does not write `.env`
- installs or updates the shared public-edge stack
- generates the single-user Authelia config, password hash, and SMTP DKIM key under the volume path
- waits for the acme-dns registration API to be ready
- registers or refreshes the `agent-app` ACME DNS client unless `--dns-skip` is used
- prints shared authdns A/NS records and app-specific records for app, auth, ACME, SPF, DKIM, and DMARC
- waits for Enter before starting services unless `--dns-skip` is used
- runs `docker compose up -d --build --force-recreate --remove-orphans` so
  regenerated volume-mounted config is loaded by fresh containers

For manual setup instead of the setup script, export the public domain values in
your shell or set them in `/opt/servers/agent-app/.env`:

```text
AGENT_APP_DOMAIN=agent.example.com
AGENT_APP_AUTH_DOMAIN=auth.agent.example.com
AGENT_APP_AUTH_USERNAME=agent
AGENT_APP_AUTH_PASSWORD=replace-with-a-long-secret
AGENT_APP_SMTP_DOMAIN=agent.example.com
ADMIN_EMAIL=admin@example.com
```

The setup script parses `.env` files as simple `KEY=value` data and does not
execute them as shell scripts. Values may contain spaces, so SSH public keys can
be written directly as `AGENT_APP_AUTHORIZED_KEYS=ssh-ed25519 AAAA... user@example.com`.

Committed examples intentionally use `example.com` placeholder values. Keep real
deployment values only in the server-side runtime environment, either exported in
the shell or pre-defined in `.env`; do not commit private domains, real email
addresses, credentials, or tokens into this template.

Then register the DNS-01 validation credentials once from the shared public
edge server, and create the CNAME printed by the script in your DNS manager:

```bash
cd /opt/servers/public-edge
sudo ./register-acme-dns-client.sh agent-app _acme-challenge.agent.example.com
```

That credential file is read from:

```text
/opt/servers/volumes/acme-dns/clients/agent-app.env
```

The certificate request includes both `${AGENT_APP_DOMAIN}` and
`*.${AGENT_APP_DOMAIN}`. `${AGENT_APP_AUTH_DOMAIN}` must be one non-numeric
direct subdomain under `${AGENT_APP_DOMAIN}` so the wildcard certificate covers
it and it cannot collide with a dynamic port hostname. The base domain proxies
to Agent App port `5900`. Dynamic wildcard hosts proxy through the shared nginx
container to matching internal container ports:

```text
https://3000.${AGENT_APP_DOMAIN} -> http://agent-app:3000
https://5173.${AGENT_APP_DOMAIN} -> http://agent-app:5173
```

Dynamic port hosts are limited to ports `1024` through `65535`, so low internal
ports such as SSH port `22` are not routable through this wildcard.

### Why `agent-app-nginx-vhost` exists

`agent-app-nginx-vhost` is a one-shot helper container. It does not run Agent
App. It reads `AGENT_APP_DOMAIN`, generates the nginx-proxy `vhost.d` override
needed for dynamic port subdomains, writes it to the shared nginx-proxy volume,
and exits before the main `agent-app` container starts.

This helper exists because nginx-proxy cannot express this routing with only
environment variables:

```text
https://3000.${AGENT_APP_DOMAIN} -> http://agent-app:3000
https://5173.${AGENT_APP_DOMAIN} -> http://agent-app:5173
```

The simpler-looking options do not fully solve that requirement:

- `VIRTUAL_HOST=*.${AGENT_APP_DOMAIN}` claims wildcard hostnames, but all of
  them still route to one static `VIRTUAL_PORT`.
- `VIRTUAL_HOST_MULTIPORTS` works for ports listed in advance, but not for open
  dynamic routing where the hostname port becomes the upstream port.
- A committed `vhost.d/*.example.com_location_override` file works only for one
  domain and breaks the reusable `AGENT_APP_DOMAIN` design.
- A regex `VIRTUAL_HOST` can capture the port, but nginx-proxy requires the
  matching custom config filename to be the SHA-1 hash of the exact regex, which
  makes the file domain-specific and hard to maintain.
- Generating the file from the main `agent-app` entrypoint is race-prone because
  nginx-proxy may regenerate its config before the file exists.
- A manual host-side script before `docker compose up` works, but breaks the
  goal that this server starts with compose only.

So the helper is the automatic option that actually preserves all requirements:
generic domain, no manual config step, and real dynamic
`<port>.${AGENT_APP_DOMAIN}` routing. It creates:

```text
/opt/servers/volumes/vhost.d/*.${AGENT_APP_DOMAIN}_location_override
```

## Public Access Gate

Authelia protects all public Agent App routes:

```text
https://${AGENT_APP_DOMAIN}
https://<port>.${AGENT_APP_DOMAIN}
```

Unauthenticated browser requests are redirected to:

```text
https://${AGENT_APP_AUTH_DOMAIN}
```

After successful login, Authelia redirects the browser back to the originally
requested URL. nginx cannot both return a 401 response body and redirect the
browser in the same response, so this setup uses the normal browser-friendly
`302` redirect flow.

This setup is intentionally single-user. The setup script asks for:

```text
AGENT_APP_AUTH_DOMAIN
AGENT_APP_AUTH_USERNAME
AGENT_APP_AUTH_PASSWORD
AGENT_APP_SMTP_DOMAIN
```

It writes Authelia config and the hashed password here:

```text
/opt/servers/volumes/agent-app/authelia/config
```

The first time the user logs in with the correct username and password,
Authelia enforces two-factor authentication and presents TOTP enrollment with a
QR code for an authenticator app.

The default Authelia session timeouts are:

```text
AGENT_APP_AUTH_SESSION_INACTIVITY=12h
AGENT_APP_AUTH_SESSION_EXPIRATION=1d
AGENT_APP_AUTH_SESSION_REMEMBER_ME=1M
```

These can be overridden in `.env` before running setup. They intentionally avoid
the old short idle timeout that could interrupt the Agent App UI while still
allowing a longer remember-me session.

## Notifications

Authelia uses one notification provider at a time. The setup script reads
`AGENT_APP_ENABLE_SMTP`, which can be `auto`, `true`, or `false`. Empty or
missing means `auto`.

In `auto` mode the setup script checks outbound TCP/25. If it is reachable,
Authelia sends registration, reset, and verification messages through a local
send-only Postfix container named `agent-app-smtp`. If TCP/25 is blocked,
Authelia writes notifications to a file and the `agent-app-notifications`
container prints them to Docker logs.

When SMTP is enabled, the SMTP container is only on the compose default
network, exposes port `25` to sibling containers, and does not publish any SMTP
port to the host or public internet. Authelia waits for the SMTP healthcheck
before starting, so its startup notification check does not race Postfix
initialization.

The Authelia-to-Postfix hop is intentionally plain SMTP inside the private
compose network. `agent-app-smtp` disables its STARTTLS advertisement because
the image's generated certificate is for `localhost`, which would fail
Authelia's certificate name verification when connecting to `agent-app-smtp`.

The SMTP defaults are:

```text
AGENT_APP_ENABLE_SMTP=auto
AGENT_APP_SMTP_DOMAIN=${AGENT_APP_DOMAIN}
Authelia sender=Authelia <authelia@${AGENT_APP_SMTP_DOMAIN}>
```

SMTP mode generates a persistent DKIM key under:

```text
/opt/servers/volumes/agent-app/smtp/opendkim
```

The DNS table printed by the setup script includes SPF, DKIM, and DMARC records
only when SMTP is enabled. If `${AGENT_APP_SMTP_DOMAIN}` is the same as
`${AGENT_APP_DOMAIN}`, no extra SMTP A record is needed because the base Agent
App A record already covers it.

This is send-only mail. No MX record is needed. Delivery still requires
outbound TCP/25 from the server to the internet; some VPS providers block
outbound TCP/25.

Filesystem mode writes notifications to:

```text
/opt/servers/volumes/agent-app/authelia/config/notification.txt
```

Follow the file with:

```bash
sudo tail -n +1 -F /opt/servers/volumes/agent-app/authelia/config/notification.txt
```

If the username is forgotten, read it from:

```text
/opt/servers/volumes/agent-app/authelia/config/users_database.yml
```

If the password is forgotten, rerun `setup-agent-app.sh` with the same username
and a new `AGENT_APP_AUTH_PASSWORD`; the script rewrites the password hash. If
the authenticator app is lost, stop Authelia and delete its SQLite database to
clear the enrolled TOTP secret:

```bash
cd /opt/servers/agent-app
sudo docker compose stop agent-app-authelia
sudo rm -f /opt/servers/volumes/agent-app/authelia/config/db.sqlite3
sudo docker compose up -d agent-app-authelia
```

For one user this is the simplest recovery path. It clears Authelia sessions and
2FA enrollment state, then the next successful password login enrolls a new
authenticator app.

```bash
cd /opt/servers/agent-app
sudo docker compose up -d --build --remove-orphans
```

## SSH Access

The SSH server listens on port `22` inside the container. The compose file maps
it to the host loopback interface by default:

```text
127.0.0.1:2222 -> container:22
```

Add an SSH public key before starting, or restart after adding it:

```bash
sudo mkdir -p /opt/servers/volumes/agent-app/ssh
printf '%s\n' 'ssh-ed25519 AAAA... your-key-name' |
  sudo tee /opt/servers/volumes/agent-app/ssh/authorized_keys >/dev/null

cd /opt/servers/agent-app
sudo docker compose up -d --build --remove-orphans
```

Then connect from the server host:

```bash
ssh -p 2222 agent@127.0.0.1
```

For a non-default host port, export or predefine:

```text
AGENT_APP_SSH_PORT=2222
```

To publish SSH beyond localhost, set:

```text
AGENT_APP_SSH_BIND=0.0.0.0
```

`setup-agent-app.sh` opens `${AGENT_APP_SSH_PORT:-2222}/tcp` in UFW when
`OPEN_AGENT_APP_SSH_PORT=true`. Set `OPEN_AGENT_APP_SSH_PORT=false` to skip
that firewall rule. When `AGENT_APP_SSH_BIND` is not already set, the setup
script defaults it to `0.0.0.0` if `OPEN_AGENT_APP_SSH_PORT=true`, or
`127.0.0.1` if `OPEN_AGENT_APP_SSH_PORT=false`. Only publish SSH beyond
localhost behind a firewall or VPN. The container disables root SSH login.

## Agent App Server

Agent App listens on port `5900` inside the container by default and is published
only to the Docker network through `expose`; it is not published to the host:

```text
container:5900
```

The supervised command is controlled by `CODEXUI_SANDBOX_MODE` and
`CODEXUI_APPROVAL_POLICY`, which default to `danger-full-access` and `never`.

```bash
SHELL=/bin/bash node /usr/local/bin/codexapp /workspace \
  --no-tunnel --no-login --no-open --no-password \
  -p 5900 \
  --sandbox-mode "${CODEXUI_SANDBOX_MODE}" \
  --approval-policy "${CODEXUI_APPROVAL_POLICY}"
```

Agent App starts with `/workspace` as the active project. The Docker container is
the isolation boundary, so the default disables Codex's inner sandbox. This is
intentional: `workspace-write` can block shell startup inside this nested
container with Bubblewrap namespace errors such as `bwrap: loopback: Failed
RTM_NEWADDR: Operation not permitted`, and it can also prevent writes outside
the active workspace or access to the inner Docker socket. Keep
`danger-full-access` when the agent is expected to run dev servers, install
project tools, or manage Docker containers inside this isolated container.

`CODEXUI_SANDBOX_MODE=workspace-write` can still be set manually for testing,
but it is not the supported default for this server layout.

The image is based on the official Playwright Docker image and then layers the
Agent App services on top. That base image provides browser binaries and their
Linux runtime dependencies, so the agent should not need to run
`playwright install-deps`, extract browser libraries into `/workspace`, or solve
Chromium shared-library errors in every new session.

The Dockerfile also installs common developer tools and media/browser helpers
such as `jq`, `ripgrep`, `fd`, `file`, `tree`, `tmux`, `shellcheck`, `pipx`,
Python virtualenv support, `ffmpeg`, ImageMagick, Poppler utilities, and common
Noto fonts. The image installs `node-pty` inside the global `codexapp` package
because the browser terminal depends on that native module.

### Disk Cleanup

Normal users should not need cleanup after every setup. These commands are
mainly for repeated setup/build attempts, Dockerfile changes, upgrades, or low
disk space on small VPS disks:

```bash
sudo docker builder prune -af
sudo docker image prune -af
```

Do not casually run `docker system prune -a --volumes`; it can delete important
volumes and service state.

Chromium and Playwright also benefit from a larger Docker shared-memory mount
than Docker's default `64M`. On a 1 GB VPS, use `shm_size: "256m"` for the
`agent-app` service. On a 2-4 GB VPS, `shm_size: "512m"` is a better default.

The `agent` user does not get passwordless sudo by default. This keeps Agent
App free to work inside the mounted workspace and user home volumes without
letting it rewrite the container runtime, global npm packages, or supervised
services. To temporarily allow root-level maintenance inside the container, set:

```text
AGENT_APP_ENABLE_SUDO=true
```

Then recreate the container:

```bash
cd /opt/servers/agent-app
sudo docker compose up -d --force-recreate
```

Set `AGENT_APP_ENABLE_SUDO=false` and recreate again to remove the sudoers file.
Changing the variable inside an Agent App shell does not grant sudo; the root
entrypoint applies the setting only when Docker creates the container.

The current Agent App command disables Agent App's own login and password gate.
Public HTTP access is expected to go through Authelia.

Additional tools started inside the container can be reached through
`https://<port>.${AGENT_APP_DOMAIN}` when they listen on that same container
port. Those tools must bind to `0.0.0.0`, not only `127.0.0.1`, because nginx
connects from another container over the `reverse_proxy` Docker network.

## Inner Docker

The container runs its own Docker daemon under `supervisord`, similar to using
systemd on a normal server. The `agent` user is in the `docker` group and uses:

```bash
DOCKER_HOST=unix:///var/run/docker.sock
```

Docker state is persisted under `/var/lib/docker`, mounted from the host volume
listed below. The Agent App container runs with `privileged: true` so the inner
daemon can create namespaces, cgroups, overlay filesystems, and container
networks. This gives the agent broad control inside the Agent App container, but
does not mount the host Docker socket.

The inner Docker daemon is pinned to non-overlapping private address ranges:

```text
docker0 bridge: 10.200.0.1/24
user networks:  10.201.0.0/16 split into /24 networks
```

Do not let the inner daemon use Docker's default `172.x` bridge ranges. Those
can overlap with the outer Docker networks, such as `reverse_proxy`, because the
inner daemon runs inside the `agent-app` network namespace. Overlap can cause
intermittent outbound connection stalls from `agent-app` while other containers
and the host remain fast.

If this setting is added after the inner Docker volume already contains old
networks, recreate the persisted inner Docker state before testing:

```bash
cd /opt/servers
sudo docker compose down
sudo rm -rf /opt/servers/volumes/agent-app/docker/*
sudo ./setup-agent-app.sh -d --dns-skip
```

After restart, `sudo docker exec agent-app ip route` should not show inner
Docker bridges using the same subnet as the outer `eth0` network.

## Optional Password Login

Key login is preferred. To enable password login for the `agent` user, export or
predefine:

```text
AGENT_APP_PASSWORD=replace-with-a-long-secret
```

When no key and no password are configured, SSH still starts but login is not
possible.

## Volumes

```text
/opt/servers/volumes/agent-app/workspace          -> /workspace
/opt/servers/volumes/agent-app/docker             -> /var/lib/docker
/opt/servers/volumes/agent-app/home               -> /home/agent
/opt/servers/volumes/agent-app/authelia/config    -> /config
/opt/servers/volumes/agent-app/smtp/opendkim      -> SMTP DKIM keys
/opt/servers/volumes/agent-app/ssh                -> authorized_keys input
/opt/servers/volumes/agent-app/sshd               -> persistent SSH host keys
```

The full `/home/agent` directory is persisted. This includes `.codex`,
`Documents`, `.local`, `.npm-global`, `.ssh`, shell history, user-installed
tools, and future application state created under the agent user's home
directory.

`CODEX_HOME` is fixed to `/home/agent/.codex`. That directory stores Codex and
Agent App state such as auth, config, UI sessions, skills, generated UI state,
and Agent App worktrees.

Projectless Agent App chats are stored by Agent App under
`/home/agent/Documents/Codex`, inside the persisted home directory.

Keep repositories and working files under `/workspace`. User-level tools
installed into `~/.local`, `pipx`, or the user npm prefix survive rebuilds.
OS-level packages installed into the running container are not a good backup
target; add them to the Dockerfile and rebuild the image when you want them to
be durable. Project-specific service stacks should usually run in the inner
Docker daemon instead of being installed globally into the Agent App container.

The image-provided `@openai/codex` and `codexapp` commands are installed under
`/usr/local/bin`, outside the mounted `/home/agent` volume. The
`/home/agent/.npm-global` directory is reserved for packages installed later by
the agent or through SSH, so an empty backup home volume cannot hide the CLIs
baked into the image.

## Installed Commands

Inside the container:

```bash
codex --help
codexapp --help
playwright --version
python3 --version
pipx --version
docker version
docker compose version
```

## Operations

```bash
cd /opt/servers/agent-app
sudo docker compose ps
sudo docker compose logs -f
```
