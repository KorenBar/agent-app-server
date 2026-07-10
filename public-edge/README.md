# Shared Public Edge

This stack owns public HTTP/HTTPS for the server.

It runs:

- `nginx-proxy` on host ports `80` and `443`
- `acme-companion` for automatic TLS certificates
- `acme-dns` on host port `53` for delegated DNS-01 certificate validation
- `autoheal` for opt-in healthcheck-based restarts

It creates the shared Docker network `reverse_proxy`. Application containers
join that network and use `nginx-proxy` environment variables:

```yaml
environment:
  VIRTUAL_HOST: app.example.com
  VIRTUAL_PORT: "8080"
  LETSENCRYPT_HOST: app.example.com
```

Only this stack should publish host ports `53`, `80`, and `443`.

## Initialize A New Server

```bash
cd /opt/servers/public-edge
sudo ./init-server.sh install
```

The script loads `/opt/servers/public-edge/.env` if it exists, prompts for
missing public-edge values, installs Docker on Ubuntu if needed, detects the
local interface address for authoritative DNS, generates the `acme-dns` config,
opens SSH, HTTP, HTTPS, and authoritative DNS in UFW, creates
`/opt/servers/volumes`, validates the compose file, pulls images, and starts the
shared proxy stack.

Required public-edge values:

```text
ADMIN_EMAIL=admin@example.com
ACME_DNS_DOMAIN=authdns.example.com
```

Optional values:

```text
ACME_DNS_NSNAME=authdns.example.com
ACME_DNS_NSADMIN=admin.example.com
ACME_DNS_BIND_IP=<local-interface-ip>
```

Entered values are used for that script run and are not written back to `.env`.

## Existing Server Cutover

If another nginx container already owns ports `80` and `443`, prepare the
shared proxy first without starting it:

```bash
cd /opt/servers/public-edge
sudo ./init-server.sh prepare-cutover
```

Then update the old application stack with `--remove-orphans` so its old nginx
container is removed. After ports `80` and `443` are free, start this stack:

```bash
sudo ./init-server.sh update
```

## Delegated DNS-01

`acme-dns` serves only the delegated validation zone configured by
`ACME_DNS_DOMAIN`, for example `authdns.example.com`. It does not provide a
public recursive resolver. Its update API is reachable from the host at
`127.0.0.1:8080` and from containers on `reverse_proxy`; it is not published to
the internet.

At Namecheap, create these records once, using this server's public IPv4:

```text
Type  Host     Value
A     authdns  <server-public-ip>
NS    authdns  authdns.example.com.
```

The `A` record supplies the address/glue for the delegated authoritative DNS
server. This validation zone is separate from application/runtime DNS records;
it only exists so Let's Encrypt can verify certificate ownership.

When `init-server.sh` runs, it detects the IPv4 address of the server interface
used for outbound traffic and exports it as `ACME_DNS_BIND_IP` for that run.
Docker binds public DNS port `53` to that interface only, avoiding a conflict
with Ubuntu's local DNS stub listener:

```bash
cd /opt/servers/public-edge
sudo ./init-server.sh update
```

On a host with an unusual routing setup or multiple public-facing interfaces,
override the detected local bind address for that invocation:

```bash
sudo ACME_DNS_BIND_IP=<local-interface-ip> ./init-server.sh update
```

This bind address is not necessarily the same as the public IP placed in
Namecheap if the server is behind NAT or a cloud public-IP mapping.

To prepare a certificate consumer, create one validation-scoped `acme-dns`
registration:

```bash
cd /opt/servers/public-edge
sudo ./register-acme-dns-client.sh <service-name> <namecheap-cname-host>
```

The command writes private ACME credentials to:

```text
/opt/servers/volumes/acme-dns/clients/<service-name>.env
```

It also prints the permanent DNS `CNAME` record to create. The host is the
requested challenge name; its value is the generated target under
`ACME_DNS_DOMAIN`, for example `*.authdns.example.com`. Once that CNAME resolves
publicly, the application container can obtain and automatically renew its
certificates.

For a future application that needs DNS-01 validation, register a separate
credential file and delegate only that application's `_acme-challenge` name:

```bash
sudo ./register-acme-dns-client.sh <service-name> <namecheap-cname-host>
```

## Custom Vhost Snippets

Custom snippets are loaded from:

```text
/opt/servers/volumes/vhost.d/
```

The filename must match the domain, for example:

```text
/opt/servers/volumes/vhost.d/app.example.com
```

## Autoheal

`autoheal` restarts containers that have both:

- a Docker healthcheck
- `labels: { autoheal: "true" }`

This keeps health-based restarts opt-in per service instead of restarting every
unhealthy container on the host.

## Operations

```bash
sudo ./init-server.sh status
sudo ./init-server.sh logs
sudo ./init-server.sh logs nginx-proxy acme-dns acme-companion autoheal
```
