# Usage Guide

`services-orchestrator` (`sorch`) is a portable nginx reverse-proxy + Let's
Encrypt SSL edge you can drop onto any VPS. Services are managed entirely through
an interactive CLI — you never hand-edit config files.

## Concepts

- **Edge** — one nginx + certbot pair per host, bound to ports 80/443.
- **`services.yml`** — the single source of truth. It is *instance state*:
  gitignored, unique per VPS, and edited only through the CLI (like `.env`).
- **Service** — one routed thing: a `docker` container, a `host` process, or a
  `static` directory. Each has domains, an optional SSL toggle, optional
  websockets, and an optional deploy hook.
- **Project** — a named group of services you can deploy as a unit.
- **Generation** — the CLI renders nginx config from `services.yml`. Only
  enabled services produce config; nothing is hand-written.

## Install on a VPS

```bash
git clone <your-fork> services-orchestrator
cd services-orchestrator
./orchestrator bootstrap     # installs docker, yq, gum, mkcert (apt/dnf/yum)
./orchestrator init          # sets email + environment, creates services.yml
```

## Command reference

| Command | Purpose |
|---|---|
| `bootstrap` | Install dependencies (auto-detects apt/dnf/yum). |
| `init` | Create `services.yml` + `.env`, set email & environment. |
| `service add` | Add a service (interactive). |
| `service edit` | Edit a service field. |
| `service remove` | Remove a service. |
| `service list` | Show all projects & services. |
| `env` | View/edit `.env` secrets. |
| `generate` | Render nginx config from `services.yml`. |
| `up [--tls] [--force]` | Start the edge. `--tls` = local self-signed HTTPS. |
| `down [--volumes]` | Stop the edge. |
| `deploy [project...]` | Run deploy hooks (optionally scoped) then bring the edge up. |
| `ssl` | Issue/renew Let's Encrypt certificates. |
| `renew` | Renew certs and reload nginx (used by cron). |
| `hosts` | Print `/etc/hosts` lines for local domains. |
| `doctor` | Check deps, ports, and config health. |

## Service types

- **docker** — proxies to a container by name over a shared Docker network.
  Set `upstream` to `container:port` and list the `networks` nginx should join.
- **host** — proxies to a process running on the VPS via
  `host.docker.internal`. Set `upstream` to a port (e.g. `8000`) or `host:port`.
- **static** — nginx serves a directory. Set `root` to the path (mount it into
  the nginx container if it lives outside the repo).

## Common workflows

### Add a service and go live (production)

```bash
./orchestrator service add       # answer the prompts
./orchestrator ssl               # issue certs for ssl:true domains
```
`ssl` first serves HTTP so the ACME challenge succeeds, obtains the certificate,
then regenerates with HTTPS enabled and reloads nginx.

### Test locally before deploying

```bash
# In services.yml, environment: local  (set during init, or re-run init)
./orchestrator hosts             # add the printed lines to your hosts file
./orchestrator up                # plain HTTP on localhost
# ...or exercise the HTTPS path with self-signed certs:
./orchestrator up --tls
```

### Deploy an app together with the edge

Give a service a `deploy` hook (e.g. `cd ../blog && git pull && docker compose up -d`).
Then:
```bash
./orchestrator deploy            # all projects' hooks, then edge up
./orchestrator deploy blog       # only the 'blog' project's hooks
```

## Local testing on Windows (Git Bash + Docker Desktop)

Run the CLI from Git Bash. `gum` menus may not render under MinTTY; the CLI
automatically falls back to numbered text prompts, so everything still works.
`host` services resolve through Docker Desktop's `host.docker.internal`.

## Tests

```bash
bash tests/run.sh              # offline: generator, validation, idempotency
bash tests/nginx-validate.sh   # runs 'nginx -t' on generated config (needs Docker)
```

## How SSL certificates work

All `ssl: true` domains are covered by a single certificate named `sorch`, so
generated nginx blocks always reference one predictable path. The certbot
container attempts renewal every 12h; in production/staging a monthly host cron
(`renew`) adds a belt-and-suspenders renew + reload.

## Choosing `upstream`: docker vs host

This is the most common source of confusion.

**`type: docker`** proxies over a shared Docker network by container name:
- `upstream` must use the container's **internal** port (what the app listens on
  *inside* the container), e.g. `myapp-caddy:80` — **not** the host-published
  port like `8002`.
- nginx must be attached to that container's network, so list it under
  `networks` (find it with `docker network ls` / `docker inspect <container>`).
- If the name can't be resolved, that service returns `502` (it no longer
  crashes the whole edge), but it still won't work until the network is correct.

**`type: host`** proxies to a port published on the host (`host.docker.internal`):
- `upstream` is the **host-published** port, e.g. `8002` (from
  `0.0.0.0:8002->80`). This is the easiest option when your app already
  publishes a port.
- The port must be published on `0.0.0.0` — a port bound only to `127.0.0.1`
  (e.g. `127.0.0.1:5678`) is **not** reachable this way; point at a
  `0.0.0.0`-published port instead (often a front proxy like Caddy).

> [!TIP]
> Run `./orchestrator doctor` — it warns if a `docker` service has no network.

## SSL behind Cloudflare

If your domains are proxied through Cloudflare (orange cloud), the Let's Encrypt
HTTP-01 challenge goes to Cloudflare, not your server, and can fail with `522`.
Options:

1. **Temporarily grey-cloud** the record (set it to "DNS only") in the
   Cloudflare dashboard, run `./orchestrator ssl`, then re-enable the proxy.
   Simplest reliable path for HTTP-01.
2. **Let Cloudflare handle TLS** at the edge and either set the origin service's
   `ssl: false` (Cloudflare "Flexible") or install a Cloudflare **Origin
   Certificate** on the origin (out of scope for `ssl`, but works with a manual
   cert). Use Full (strict) with an origin cert for real security.

## Troubleshooting

**`docker ps` shows `sorch-nginx` Restarting** — nginx couldn't start. Almost
always a bad upstream. Check the log:

```bash
docker logs --tail 50 sorch-nginx
```

`host not found in upstream "<name>"` means a `docker` service points at a
container nginx can't resolve — fix the network (or switch to `type: host`).
After any config change: `./orchestrator generate && docker exec sorch-nginx nginx -t`.
