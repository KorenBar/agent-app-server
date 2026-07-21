# Standalone Paseo VPS

This setup installs Paseo and its development tools directly on an Ubuntu VPS.
It does not use or modify the repository's containerized Agent App stack.

Paseo listens only on `127.0.0.1:6767`. Remote clients connect through Paseo's
end-to-end encrypted relay, so port `6767` is not opened in UFW and no public
TLS proxy is needed.

## Requirements

- A fresh Ubuntu VPS with root access. Ubuntu 24.04 is the tested target.
- Internet access for apt, npm, Docker, Playwright browsers, and Paseo's relay.
- Enough disk for Docker and all Playwright browsers; 40 GB or more is practical.
- Prefer 4 GB RAM or more when running browser tests and coding agents together.

## Security Boundary

The `paseo` user is in the `docker` group. This allows Paseo agents and terminals
to manage containers without `sudo`, but Docker access is effectively root access
to the VPS. Use a dedicated VPS and treat every enabled agent as trusted.

Docker ports published without an explicit host address bind to `127.0.0.1` by
default on both the default bridge and user-defined bridges created by Compose.
An agent with Docker access can still deliberately bind a port to `0.0.0.0`, use
Swarm's public routing mesh, or change the host configuration.

## Configuration

Create `standalone-paseo/.env` beside the setup script. The file is ignored by
the repository's existing `.gitignore` rule.

```dotenv
PASEO_USER_PASSWORD='replace-with-a-password'
PASEO_AUTHORIZED_KEY=ssh-ed25519 AAAAC3... workstation
PASEO_SSH_PASSWORD_AUTH=auto
```

Protect the file because it contains the Unix password:

```bash
chmod 600 standalone-paseo/.env
```

The script rejects an `.env` file that is accessible by group or other users on
Ubuntu. It also rejects variable names other than the three listed below.

| Variable | Required | Meaning |
|---|---:|---|
| `PASEO_USER_PASSWORD` | yes | Unix password for `paseo` and password-protected sudo. |
| `PASEO_AUTHORIZED_KEY` | no | One OpenSSH public key, appended to both root and `paseo`. |
| `PASEO_SSH_PASSWORD_AUTH` | no | `auto`, `true`, or `false`; defaults to `auto`. |

With `auto`, SSH password login for `paseo` is disabled when a public key is
provided and enabled when no key is provided. Root SSH policy is never changed;
the optional public key is only appended to root's existing authorized keys.

Process environment values take precedence over `.env`. Missing values are
prompted, and prompted answers are not written back to disk. A noninteractive
run must provide `PASEO_USER_PASSWORD`.

## Install

From the repository root:

```bash
cd standalone-paseo
sudo bash ./setup-paseo-vps.sh
```

The script installs the host packages, Node.js 24, Docker CE, Paseo, Codex,
Claude Code, Playwright 1.61, and all Playwright browsers. It creates `/workspace`
for projects and starts `paseo.service` at boot. UFW keeps existing rules, allows
port 22, and also preserves the current SSH server port when setup is run through
a nonstandard SSH port.

Preinstalled npm tools live under `/usr/local`. The initially empty
`/home/paseo/.npm-global` prefix is reserved for tools installed later by the
`paseo` user or an agent.

## Pair A Client

Generate a pairing offer as the daemon user:

```bash
sudo -u paseo -H /usr/local/bin/paseo daemon pair --json
```

Open the returned `https://app.paseo.sh/#offer=...` URL, or scan its QR code from
the Paseo mobile app. Treat the pairing URL like a password.

The bundled self-hosted web UI is intentionally disabled. The daemon remains on
localhost while its outbound relay connection handles remote access.

## SSH And Provider Login

Connect to the development account:

```bash
ssh paseo@SERVER_IP
```

Authenticate each preinstalled provider as `paseo` so the daemon and its agents
use the same credentials:

```bash
sudo -iu paseo
cd /workspace
codex login
claude
```

Provider state is stored under `/home/paseo`, including `.codex` and `.claude`.

## Playwright

Paseo shells, agents, and terminals receive the paths needed to use the global
Playwright package and browsers without sudo:

```bash
sudo -iu paseo
playwright --version
node -e 'const { chromium } = require("playwright"); chromium.launch({headless:true}).then(async b => { console.log(await b.version()); await b.close(); })'
```

Project-local npm dependencies can still be installed normally. Future global
tools installed by `paseo` go to its home prefix:

```bash
npm install -g PACKAGE_NAME
npm prefix -g
```

## Private Development Ports

Docker publishes unspecified host addresses on VPS loopback. Forward one port
to a PC with SSH:

```bash
ssh -N -L 5173:127.0.0.1:5173 paseo@SERVER_IP
```

Then open `http://127.0.0.1:5173` on the PC. For several changing ports, use a
SOCKS proxy and configure the client to use it:

```bash
ssh -N -D 127.0.0.1:1080 paseo@SERVER_IP
```

## Updates

Rerun the setup script with the same `.env` file:

```bash
cd standalone-paseo
sudo bash ./setup-paseo-vps.sh
```

This updates apt and npm packages, reinstalls the pinned Playwright release,
and restarts Paseo. Running agents and terminals are interrupted during the
update, so finish or stop them first.

## Operations

```bash
sudo systemctl status paseo
sudo journalctl -u paseo -f
sudo systemctl restart paseo
curl -fsS http://127.0.0.1:6767/api/health
sudo -u paseo -H /usr/local/bin/paseo daemon status
```

Docker and firewall checks:

```bash
sudo -u paseo -H docker info
sudo ufw status verbose
sudo jq . /etc/docker/daemon.json
```

## Recovery

- Change the `paseo` Unix password by updating `.env` and rerunning setup.
- Add another SSH key with `ssh-copy-id paseo@SERVER_IP`; setup never deletes keys.
- Reauthenticate providers with `sudo -iu paseo`, then `codex login` or `claude`.
- Generate a fresh client offer with `paseo daemon pair --json` as shown above.
- Diagnose startup failures with `journalctl -u paseo -n 100 --no-pager` and
  `/home/paseo/.paseo/daemon.log`.
