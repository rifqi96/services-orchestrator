# services-orchestrator — Design Spec

**Date:** 2026-07-09
**Status:** Approved (brainstorming phase)
**Author:** Rifqi (with Claude)

## 1. Purpose

A portable, reusable reverse-proxy + SSL orchestrator that can front an arbitrary
set of services (any project, any VPS) without hand-editing config files. It
replaces the hardcoded, project-specific approach of `kontinentalist-orchestrator`
with a declarative, CLI-driven model.

The user must be able to drop this repo onto any fresh VPS, run one bootstrap
command, then add/remove/deploy services entirely through an interactive CLI —
no knowledge of nginx, Docker networking, or the config file format required.

## 2. Background: what we are generalizing

`kontinentalist-orchestrator` runs a central nginx reverse proxy + certbot
(Let's Encrypt) container that fronts a fixed set of hardcoded apps. Its key
patterns, and their limitations:

- **Edge stack** — nginx + certbot in `docker-compose.yml`, sharing external
  Docker networks with each app. *Keep this; it works.*
- **Per-service enable flags** in `.env` (`LAPIS=true`, `N8N=true`) consumed as
  Docker build args. *Replace with a declarative service list.*
- **nginx templating via deletion** — every app's `.conf` is baked into the
  image, then the Dockerfile `rm`s the ones whose flag is off
  (`if [ -z "$N8N" ]; rm n8n*`). Adding an app means writing 3–4 nginx files by
  hand and editing the Dockerfile's delete logic. *This is the worst trait;
  replace with generation.*
- **Two workload styles** — Dockerized apps (proxied by container name over a
  shared network) and host processes (proxied via `host.docker.internal:PORT`,
  e.g. n8n, slack-events). *Keep both, add static sites.*
- **Local vs prod configs** — `.local.conf` (HTTP only) for dev, `.conf` +
  `include.d/*.ssl.conf` for prod, selected in the Dockerfile by
  `ENVIRONMENT`. *Replace with generated output driven by an `environment` key.*
- **App lifecycle** — `deploy.sh` git-pulls the orchestrator, then `cd`s into
  each app dir and runs the app's own `deploy.sh`. *Generalize into optional
  per-service deploy hooks.*

## 3. Requirements & decisions

| Decision | Choice |
|---|---|
| Source of truth | Declarative `services.yml`, but **CLI-managed instance state** (gitignored, never hand-edited or committed) — treated like `.env` |
| Config interface | Interactive Bash CLI (gum menus, plain-`read` fallback) is the only way to edit config; usable by anyone |
| Workload types | Dockerized apps, host processes, static sites |
| CLI stack | Bash + `gum` + `yq` (mikefarah); no language runtime required on the VPS |
| App lifecycle | Edge (proxy + SSL + networking) always; **optional** per-service deploy hook |
| Project model | One edge instance per VPS, **multi-project aware** — services grouped under named projects, enable/deploy per group |
| Local testing | `environment: local` → HTTP-only on localhost by default; `--tls` flag spins self-signed certs (mkcert) to exercise the SSL path |
| Priority | Best developer experience: validation, `doctor` preflight, idempotent generation, clear output |

### Explicitly out of scope (YAGNI)

- Proxying to arbitrary external URLs/hosts not on this machine.
- Load balancing across multiple upstream replicas.
- A web UI (CLI only).
- Managing the apps' own internal environment variables (each app owns its env).

## 4. Architecture

```
                         services.yml  (CLI-managed, gitignored)
                               │
                        ┌──────▼───────┐
        interactive     │  orchestrator │   subcommands: init, service,
        gum menus  ───► │      CLI      │   env, generate, up, down,
                        └──────┬───────┘   deploy, ssl, doctor
                               │ generate
                        ┌──────▼───────┐
                        │  generator   │  yq + templates → nginx confs
                        │              │  + compose overrides + network list
                        └──────┬───────┘
                               │
              ┌────────────────▼─────────────────┐
              │   edge stack (docker-compose)     │
              │   nginx  ◄── generated conf.d/    │
              │   certbot (Let's Encrypt + cron)  │
              └───┬───────────┬───────────┬───────┘
        docker app        host process   static root
     (shared network)  (host.docker.internal)  (nginx root)
```

### 4.1 Config model (`services.yml`)

```yaml
defaults:
  certbot_email: you@example.com
  environment: production        # production | staging | local

projects:
  myblog:
    enabled: true
    services:
      - name: blog
        domains: [blog.example.com]
        type: docker              # docker | host | static
        upstream: blog-web:3000   # container:port
        networks: [blog-net]      # external docker networks to join
        ssl: true
        websocket: false
        deploy: "cd ../blog && git pull && docker compose up -d"  # optional
      - name: api
        domains: [api.example.com]
        type: host
        upstream: 127.0.0.1:8000  # rendered as host.docker.internal:8000
        ssl: true
      - name: site
        domains: [example.com, www.example.com]
        type: static
        root: /var/www/site/dist
        ssl: true
```

**Field reference**

- `type: docker` — requires `upstream` (`container:port`) and usually `networks`.
- `type: host` — requires `upstream` (`host:port`); rendered to
  `host.docker.internal:PORT`. For daemons/systemd/pm2 services on the VPS.
- `type: static` — requires `root` (a path nginx serves with `try_files`).
- `ssl: true` — include in certbot domain set; generate HTTP→HTTPS redirect +
  HTTPS server block. `ssl: false` or `environment: local` → plain HTTP only.
- `websocket: true` — add `Upgrade`/`Connection` proxy headers.
- `deploy` — optional shell hook run by `orchestrator deploy`. Blank = edge-only.
- `enabled` (project-level) — skip generation/deploy for a whole project.

`services.yml` is **runtime state**: gitignored, created and mutated only by the
CLI. The repo ships `services.example.yml`. Every write is preceded by
validation and a timestamped backup (`services.yml.bak`).

### 4.2 The CLI (`./orchestrator <command>`)

| Command | Behavior |
|---|---|
| `bootstrap` | Check/install deps: docker, docker compose, `yq`, `gum` (and `mkcert` for local TLS). Idempotent. |
| `init` | Scaffold `services.yml` + `.env` from examples; prompt for `certbot_email`, `environment`. |
| `service add` | Interactive: pick/create project, name, type, domains, upstream/root, ssl, websocket, optional deploy hook → validate → write. |
| `service edit` | Pick a service via gum list → edit fields → validate → write. |
| `service remove` | Pick a service → confirm → remove → regenerate. |
| `service list` | Human-readable table of projects/services/domains/status. |
| `env` | Interactive editor for `.env` secrets/host-specifics. |
| `generate` | Render nginx confs + compose network overrides from `services.yml`. Idempotent; safe to run anytime. |
| `up [project…]` | `generate` (if stale) → create networks → `docker compose up -d` the edge, optionally scoped to project(s). `--tls` for local self-signed. |
| `down [project…]` | Stop the edge (or scope). |
| `deploy [project…]` | `generate` → run each in-scope service's deploy hook → `up`. The one-command "update everything," generalized. |
| `ssl` | Issue/renew certs for all `ssl:true` domains (generalized `init-letsencrypt`), staging toggled by `environment`. |
| `doctor` | Preflight: deps present, ports 80/443 free, no duplicate domains, upstreams parse, referenced networks/roots exist. Actionable output. |

All interactive prompts use `gum`; when `gum` is absent the CLI falls back to
plain `read` prompts so nothing hard-breaks. The CLI is a set of focused,
sourced Bash modules (one file per concern) rather than a monolith.

### 4.3 The generator

The heart of the system, and the deliberately-isolated risky part. Reads
`services.yml` with `yq`, iterates enabled projects → enabled services, and for
each renders nginx blocks from `templates/`:

- **docker** → `proxy_pass http://<upstream>;` and record `networks` to join.
- **host** → `proxy_pass http://host.docker.internal:<port>;`.
- **static** → `root <root>; try_files $uri $uri/ =404;`.
- **SSL, non-local** → HTTP server block (ACME challenge location +
  `301 → https`) **and** an HTTPS server block referencing the cert paths.
- **local / `ssl:false`** → single plain-HTTP server block.
- **websocket** → add upgrade headers to the `location` block.

Outputs go to a generated directory that nginx bind-mounts. **Only enabled
services produce files** — this is what eliminates the Dockerfile deletion hack.
The generator also emits the union of `networks:` across enabled services so
`up` can `docker network create` them and the compose file can attach nginx to
them. Generation is idempotent: it writes to a temp dir and swaps, so a failed
run never leaves nginx with a half-written config.

Templating uses `yq` for parsing and `envsubst`/Bash heredocs for rendering,
kept in versioned template files so the nginx output is easy to review and diff.

### 4.4 Edge stack

A generic `docker-compose.yml` mirroring the proven original: `nginx` +
`certbot`. Differences:

- nginx bind-mounts the **generated** `conf.d/` — no build args, no baked-in
  per-app logic, no Dockerfile surgery ever.
- External networks are supplied by the generator, not hardcoded.
- certbot volumes and the 12-hour renewal loop are reused as-is.
- Cert-renewal cron installer generalized from the original `shell_scripts`
  (paths derived, not hardcoded to `ec2-user`).

### 4.5 Local vs. deploy parity

The same `services.yml` drives both. `environment: local` makes `generate`
skip certbot and serve HTTP on localhost. `up --tls` (local only) uses `mkcert`
to produce self-signed certs so the HTTPS path can be tested before deploying.
A helper (`orchestrator hosts`) prints the `/etc/hosts` lines for local domains.
What you test locally is byte-for-byte what deploys, minus the cert authority.

## 5. Error handling & safety

- Every `services.yml` mutation is validated before write and backed up after.
- `generate` is atomic (temp dir + swap); nginx never sees a partial config.
- `doctor` runs the same validations independently and is invoked automatically
  before `up`/`deploy`, with a `--force` override.
- `deploy` hooks run with clear per-service logging; a failing hook stops the
  run and reports which service failed (no silent partial deploys).
- Missing deps produce a single actionable message pointing at `bootstrap`.

## 6. Testing strategy

- **Generator unit tests** (bats or plain shell asserts): given a fixture
  `services.yml`, assert the rendered nginx matches expected output for each
  `type`, ssl on/off, websocket on/off, and local vs prod.
- **`doctor` tests**: feed known-bad configs (duplicate domains, missing root,
  bad upstream) and assert it flags them.
- **Local smoke test**: a fixture project with one docker, one host, one static
  service brought up via `up --tls` locally, curled end-to-end.
- **Idempotency test**: `generate` twice → no diff; `up` twice → no error.

## 7. Repo layout (target)

```
services-orchestrator/
├── orchestrator                 # CLI entrypoint (dispatches to lib/)
├── lib/                         # sourced bash modules: cli, service, generate,
│                                #   ssl, doctor, env, ui (gum wrappers), yaml
├── templates/                   # nginx server-block templates per type/mode
├── docker-compose.yml           # edge: nginx + certbot
├── nginx/
│   ├── Dockerfile               # minimal; mounts generated conf.d
│   ├── conf.d/                  # GENERATED (gitignored)
│   └── certbot/                 # cert volumes (gitignored contents)
├── shell_scripts/               # cron cert-renew (generalized)
├── services.example.yml
├── .env.example
├── bootstrap.sh
├── docs/
│   ├── specs/                   # this file
│   └── implementation-plan/     # created next via create-implementation-plan
└── README.md                    # created last via create-readme
```

## 8. Known trade-off (accepted)

Bash + `yq` templating is more fragile than a typed language for the generator.
Accepted for VPS portability (no runtime to install) and parity with the
existing repo. Mitigations: the generator is an isolated module, templates are
versioned and diffable, generation is atomic, and `doctor` catches config
errors early. Escape hatch: if the generator becomes painful, port *only* it to
a small script while keeping the Bash CLI shell.
