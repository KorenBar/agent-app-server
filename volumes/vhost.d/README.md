# vhost.d

Per-domain nginx snippets for `nginx-proxy`.

Create a file named exactly like the domain, for example `app.example.com`,
when a service needs custom nginx locations or headers beyond the standard
`VIRTUAL_HOST` / `VIRTUAL_PORT` routing.
