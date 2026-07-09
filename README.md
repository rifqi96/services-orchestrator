# services-orchestrator

A portable nginx reverse-proxy + Let's Encrypt SSL edge you can drop onto **any
VPS** to front **any set of services** — Dockerized apps, host processes, or
static sites — all managed through an interactive CLI. No hand-edited nginx
files, no per-project boilerplate.

It generalizes a hardcoded, single-project orchestrator into a reusable tool:
services are described in a CLI-managed `services.yml`, and the CLI *generates*
all nginx configuration and Docker wiring from it.

## Highlights

- **One CLI, any project.** Add a service with a few prompts; the CLI writes the
  config and regenerates nginx. You never touch nginx or the config file format.
- **Three workload types.** Proxy to Docker containers, to host processes
  (`host.docker.internal`), or serve static directories.
- **Automatic HTTPS.** Let's Encrypt issuance + auto-renewal for every SSL
  domain, behind a single certificate.
- **Local-first.** Test the exact same config locally over HTTP, or over HTTPS
  with self-signed certs, before deploying.
- **Portable.** Pure Bash + `yq` + `gum`; a `bootstrap` command installs
  everything and auto-detects apt/dnf/yum. Runs on a fresh VPS or on Windows via
  Git Bash + Docker Desktop.
- **Safe by design.** Config is validated on every change, generation is atomic
  and idempotent, and a `doctor` command preflights deps, ports, and health.

## How it works

```
services.yml  ──►  orchestrator generate  ──►  nginx/conf.d/*.conf  ──►  nginx + certbot (Docker)
 (CLI-managed)        (yq + templates)          (only enabled svcs)         proxies to your apps
```

`services.yml` is the single source of truth. Because the generator writes
config **only for enabled services**, adding or removing a service is just a
regenerate — there is no image rebuild and no config to delete by hand.

## Quick start

### On a VPS

```bash
git clone <your-fork> services-orchestrator
cd services-orchestrator

./orchestrator bootstrap     # install docker, yq, gum, mkcert (auto-detects apt/dnf/yum)
./orchestrator init          # set email + environment; creates services.yml
./orchestrator service add   # add your first service (interactive)
./orchestrator ssl           # issue Let's Encrypt certificates
```

### Locally (test before you deploy)

```bash
./orchestrator init          # choose environment: local
./orchestrator service add
./orchestrator hosts         # prints /etc/hosts lines for your local domains
./orchestrator up            # plain HTTP on localhost
# or exercise the HTTPS path with self-signed certs:
./orchestrator up --tls
```

> [!NOTE]
> On Windows, run the CLI from **Git Bash** against **Docker Desktop**. If `gum`
> menus don't render under MinTTY, the CLI automatically falls back to numbered
> text prompts.

## Commands

| Command | Purpose |
|---|---|
| `bootstrap` | Install dependencies (apt/dnf/yum auto-detected). |
| `init` | Create `services.yml` + `.env`; set email & environment. |
| `service add \| edit \| remove \| list` | Manage services interactively. |
| `env` | View/edit `.env` secrets. |
| `generate` | Render nginx config from `services.yml`. |
| `up [--tls] [--force]` | Start the edge (`--tls` = local self-signed HTTPS). |
| `down [--volumes]` | Stop the edge. |
| `deploy [project...]` | Run deploy hooks (optionally scoped), then bring the edge up. |
| `ssl` / `renew` | Issue / renew Let's Encrypt certificates. |
| `hosts` | Print `/etc/hosts` lines for local domains. |
| `doctor` | Check deps, ports, and config health. |

## Defining services

Services are grouped into **projects**. Each service is one of three types:

- **docker** — `upstream: container:port`, joined to shared `networks`.
- **host** — `upstream: 8000` (or `host:port`), proxied via `host.docker.internal`.
- **static** — `root: /path/to/dist`, served directly by nginx.

Each service can enable `ssl`, enable `websocket`, and declare an optional
`deploy` hook (e.g. `cd ../blog && git pull && docker compose up -d`) that
`orchestrator deploy` runs for you. A service with no hook is edge-only.

> [!TIP]
> `services.yml` is instance state: it is gitignored and unique per host, and is
> only ever written by the CLI — just like `.env`. See `services.example.yml`
> for the shape it produces.

## Requirements

- Docker Engine + Docker Compose v2
- `yq` (mikefarah), `gum` (optional; plain prompts otherwise), `envsubst`
- `mkcert` (only for local `--tls`)

All of these are installed by `./orchestrator bootstrap`.

## Testing

```bash
bash tests/run.sh              # offline: generator, validation, idempotency (needs yq)
bash tests/nginx-validate.sh   # runs 'nginx -t' on generated config (needs Docker)
```

## Documentation

- [Usage guide](docs/usage.md) — concepts, command reference, workflows.
- [Design spec](docs/specs/2026-07-09-services-orchestrator-design.md)
- [Implementation plan](docs/implementation-plan/feature-services-orchestrator-1.md)
