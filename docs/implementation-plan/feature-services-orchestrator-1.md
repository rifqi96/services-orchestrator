---
goal: Build services-orchestrator — a portable, CLI-driven reverse-proxy + SSL orchestrator
version: 1.0
date_created: 2026-07-09
last_updated: 2026-07-09
owner: Rifqi
status: 'Planned'
tags: [feature, infrastructure, architecture, cli]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Implementation plan for `services-orchestrator`: a reusable, portable orchestrator
that fronts arbitrary services (Dockerized apps, host processes, static sites) on
any VPS with nginx + Let's Encrypt. All configuration is managed through an
interactive Bash CLI backed by a declarative, CLI-managed `services.yml`. This plan
is derived from `docs/specs/2026-07-09-services-orchestrator-design.md` and is
structured for autonomous, phase-by-phase execution.

## 1. Requirements & Constraints

- **REQ-001**: `services.yml` is the single source of truth for projects/services and is mutated ONLY by the CLI; it is gitignored instance state (never hand-edited or committed).
- **REQ-002**: Support three workload types: `docker` (proxy to `container:port` over a shared network), `host` (proxy to `host.docker.internal:port`), `static` (nginx `root`).
- **REQ-003**: The generator writes nginx config ONLY for enabled services; no Dockerfile-based deletion logic may exist.
- **REQ-004**: Each service may optionally declare a `deploy` shell hook; blank hook = edge-only for that service.
- **REQ-005**: Services are grouped under named `projects`; CLI operations (`up`, `down`, `deploy`) accept an optional project scope.
- **REQ-006**: `environment: local` serves HTTP-only on localhost with no certbot; `up --tls` uses `mkcert` self-signed certs.
- **REQ-007**: Single edge instance per VPS binding ports 80/443.
- **REQ-008**: `bootstrap` auto-detects the package manager (`apt` | `dnf` | `yum`) and installs docker, docker compose, `yq` (mikefarah), `gum`, and (for local) `mkcert`.
- **SEC-001**: Certbot staging mode is forced unless `environment` is `production` or `staging`.
- **SEC-002**: Every `services.yml` write is validated before commit and a timestamped `.bak` is created after.
- **CON-001**: CLI implemented in Bash only; no Node/Python/Ruby runtime dependency on the VPS.
- **CON-002**: Must run under Git Bash on Windows against Docker Desktop for local testing: enforce LF line endings, avoid `tput`-dependent logic, and provide a plain-`read` fallback for every `gum` prompt (gum TTY is unreliable under MinTTY).
- **CON-003**: `generate` must be idempotent and atomic (render to temp dir, then swap).
- **GUD-001**: CLI is composed of small, single-responsibility Bash modules in `lib/`, sourced by a thin `orchestrator` dispatcher.
- **GUD-002**: nginx output is produced from versioned template files in `templates/` for reviewability/diffability.
- **PAT-001**: Reuse the proven nginx + certbot + shared-network + 12h-renewal-loop pattern from `kontinentalist-orchestrator`, generalized (no hardcoded paths/users/service names).

## 2. Implementation Steps

### Implementation Phase 1 — Repo scaffolding & portability guardrails

- GOAL-001: Establish repo structure, portability config, and example files so all later phases have a home.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | Create directory tree: `lib/`, `templates/`, `nginx/conf.d/`, `nginx/certbot/{conf,www,logs}/`, `nginx/logs/`, `shell_scripts/`, `docs/`. Add `.gitkeep` where dirs must persist but contents are gitignored. | | |
| TASK-002 | Add `.gitattributes` enforcing `* text=auto eol=lf` and `*.sh text eol=lf` (CON-002). Add `.editorconfig` (space indent 2, LF, final newline). | | |
| TASK-003 | Verify/extend `.gitignore`: `services.yml`, `services.yml.bak`, `.env`, `.env.local`, `nginx/conf.d/`, `nginx/certbot/{conf,www,logs}/`, `nginx/logs/`, `*.log`, `CLAUDE.md`. | | |
| TASK-004 | Author `services.example.yml` demonstrating one `docker`, one `host`, one `static` service across two projects, with `defaults` block (`certbot_email`, `environment`). | | |
| TASK-005 | Author `.env.example` with documented secrets/host-specific keys (`ENVIRONMENT`, `CERTBOT_EMAIL`, `CERTBOT_STAGING`, optional per-host overrides). | | |

### Implementation Phase 2 — CLI shell, UI layer, and YAML access

- GOAL-002: Build the CLI dispatcher, the gum/read UI abstraction, and a `yq`-backed YAML read/write module.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-006 | Create `orchestrator` (executable) — thin dispatcher that sources `lib/*.sh`, parses `<command> [args] [--flags]`, prints usage, and routes to `cmd_<name>` functions. | | |
| TASK-007 | Create `lib/ui.sh` — wrappers `ui_choose`, `ui_input`, `ui_confirm`, `ui_multichoose`, `ui_info/warn/error/success`. Each detects `gum`; falls back to plain `read`/`select` (CON-002). No `tput`. | | |
| TASK-008 | Create `lib/yaml.sh` — helpers over `yq`: `yaml_get`, `yaml_set`, `yaml_delete`, `yaml_list_projects`, `yaml_list_services`, `yaml_service_field`. All operate on `services.yml`. | | |
| TASK-009 | Create `lib/config.sh` — `config_validate` (schema checks: required fields per type, duplicate-domain detection, upstream/root sanity), `config_backup`, `config_atomic_write`. | | |

### Implementation Phase 3 — The generator

- GOAL-003: Render nginx configuration and the network set deterministically from `services.yml`.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-010 | Author nginx templates in `templates/`: `http-redirect.conf.tmpl` (ACME challenge + 301), `server-docker.conf.tmpl`, `server-host.conf.tmpl`, `server-static.conf.tmpl`, `ssl-params.conf.tmpl`, plus a `websocket-headers.partial`. Use `${VAR}` placeholders. | | |
| TASK-011 | Create `lib/generate.sh` — `cmd_generate`: iterate enabled projects→services; select template by `type` and `ssl`/`environment`; substitute vars via `envsubst`; render websocket headers when `websocket: true`. | | |
| TASK-012 | Implement atomic output (CON-003): render into `nginx/.conf.d.tmp/`, validate non-empty, then `rm -rf nginx/conf.d && mv`. Compute the union of `networks:` and write `nginx/.networks` (newline list) for `up` to consume. | | |
| TASK-013 | Implement local/no-SSL branch: when `environment: local` or `ssl: false`, emit a single plain-HTTP server block (no redirect, no cert refs). | | |

### Implementation Phase 4 — Edge stack (nginx + certbot + SSL + cron)

- GOAL-004: Provide the runtime edge and generalized SSL issuance/renewal.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-014 | Author `docker-compose.yml`: `nginx` (bind-mount `./nginx/conf.d` + certbot volumes, ports 80/443, `extra_hosts: host.docker.internal:host-gateway`) and `certbot` (12h renew loop). External networks injected at runtime. | | |
| TASK-015 | Author minimal `nginx/Dockerfile` (nginx:alpine + bash) OR use the stock nginx image directly with mounts — prefer stock image; document choice. No build args, no conf deletion. | | |
| TASK-016 | Create `lib/ssl.sh` — `cmd_ssl`: collect all `ssl:true` domains from `services.yml`, generalize `init-letsencrypt` (dummy cert → nginx up → real cert), force `--staging` unless env is production/staging (SEC-001). | | |
| TASK-017 | Create `shell_scripts/cron-renew-cert.sh` and `lib/cron.sh` — install/remove a monthly renewal cron using derived `$HOME`/repo paths (no hardcoded `ec2-user`). Installed only when env is production/staging. | | |

### Implementation Phase 5 — CLI commands (full surface)

- GOAL-005: Implement every user-facing command with interactive UX and validation.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-018 | `lib/bootstrap.sh` — `cmd_bootstrap`: detect `apt`/`dnf`/`yum` (REQ-008), install docker, docker compose plugin, `yq`, `gum`, `mkcert`; idempotent; verify versions. | | |
| TASK-019 | `lib/init.sh` — `cmd_init`: copy examples if absent, prompt for `certbot_email` + `environment`, write initial `services.yml` + `.env`. | | |
| TASK-020 | `lib/service.sh` — `cmd_service add/edit/remove/list`: interactive flows (project pick/create, name, type, domains, upstream/root, ssl, websocket, optional deploy hook) → `config_validate` → `config_atomic_write` → auto `generate`. | | |
| TASK-021 | `lib/env.sh` — `cmd_env`: interactive `.env` viewer/editor for secrets/host-specifics. | | |
| TASK-022 | `lib/lifecycle.sh` — `cmd_up`/`cmd_down` (optional project scope, `--tls`), `cmd_deploy` (generate → run in-scope `deploy` hooks with per-service logging, stop on failure → up). Create networks from `nginx/.networks`. | | |
| TASK-023 | `lib/doctor.sh` — `cmd_doctor`: verify deps present, ports 80/443 free, no duplicate domains, upstreams parse, referenced roots/networks exist; actionable output; `--force` bypass; auto-run before `up`/`deploy`. | | |
| TASK-024 | `lib/hosts.sh` — `cmd_hosts`: print `/etc/hosts` lines for all local-mode domains. | | |

### Implementation Phase 6 — Local mode & self-signed TLS

- GOAL-006: Make "test before deploy" fully functional on Git Bash + Docker Desktop.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-025 | Wire `up --tls`: generate self-signed certs via `mkcert` into the certbot cert path; template SSL blocks to reference them; skip certbot entirely. | | |
| TASK-026 | Ensure `host` upstreams resolve on Docker Desktop (host.docker.internal) and document the Windows/Git Bash run steps. | | |

### Implementation Phase 7 — Tests & verification

- GOAL-007: Prove the generator, validation, and end-to-end path work.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-027 | Add `tests/` with `bats` (or plain shell asserts if bats absent): generator fixtures asserting rendered nginx for each `type` × ssl on/off × websocket on/off × local vs prod. | | |
| TASK-028 | Add `doctor`/validation tests: duplicate domains, missing `root`, malformed `upstream`, missing required fields each flagged. | | |
| TASK-029 | Idempotency test: `generate` twice → zero diff; `up` twice → no error. | | |
| TASK-030 | Local smoke test script: fixture project (1 docker via a tiny nginx/echo container, 1 static, 1 host echo) → `up --tls` → `curl` each endpoint → assert 200. | | |

### Implementation Phase 8 — Documentation

- GOAL-008: Complete in-repo documentation.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-031 | Update plan/spec statuses; add `docs/usage.md` (command reference + common workflows: add a service, deploy a project, go local). | | |
| TASK-032 | Generate `README.md` via the `create-readme` skill (quickstart, concepts, command table, local vs prod). | | |

## 3. Alternatives

- **ALT-001**: Node/Python CLI for richer prompts and typed YAML handling — rejected to keep the VPS runtime-free (CON-001) and match the existing repo.
- **ALT-002**: Keep the flat `.env` + per-service flags model — rejected; cannot express N services with distinct domains/upstreams without hardcoding.
- **ALT-003**: nginx Dockerfile that bakes all confs and deletes disabled ones (current repo) — rejected; the generation-only-for-enabled approach removes the maintenance hazard.
- **ALT-004**: Committing `services.yml` to git — rejected; it is per-VPS instance state, treated like `.env`.
- **ALT-005**: Traefik/Caddy label-based auto-discovery instead of generated nginx — rejected to preserve explicit, reviewable config and continuity with the known-good nginx pattern.

## 4. Dependencies

- **DEP-001**: Docker Engine + Docker Compose v2 (`docker compose`).
- **DEP-002**: `yq` (mikefarah, Go single-binary) for YAML parsing/writing.
- **DEP-003**: `gum` (charmbracelet) for interactive prompts; optional at runtime (plain-`read` fallback).
- **DEP-004**: `certbot/certbot` Docker image for Let's Encrypt.
- **DEP-005**: `mkcert` for local self-signed TLS (local mode only).
- **DEP-006**: `envsubst` (gettext) for template rendering; `bats-core` for tests (optional).

## 5. Files

- **FILE-001**: `orchestrator` — CLI dispatcher/entrypoint.
- **FILE-002**: `lib/ui.sh`, `lib/yaml.sh`, `lib/config.sh` — foundation modules.
- **FILE-003**: `lib/generate.sh` + `templates/*.tmpl` — nginx generator.
- **FILE-004**: `lib/ssl.sh`, `lib/cron.sh`, `shell_scripts/cron-renew-cert.sh` — SSL + renewal.
- **FILE-005**: `lib/bootstrap.sh`, `lib/init.sh`, `lib/service.sh`, `lib/env.sh`, `lib/lifecycle.sh`, `lib/doctor.sh`, `lib/hosts.sh` — command implementations.
- **FILE-006**: `docker-compose.yml`, `nginx/Dockerfile` — edge stack.
- **FILE-007**: `services.example.yml`, `.env.example`, `.gitattributes`, `.editorconfig`, `.gitignore`.
- **FILE-008**: `tests/*` — generator, validation, idempotency, smoke tests.
- **FILE-009**: `docs/usage.md`, `README.md` — documentation.

## 6. Testing

- **TEST-001**: Generator output matches expected nginx for `type=docker|host|static`.
- **TEST-002**: SSL on/off and `environment=local|production` produce correct server-block shape (redirect+HTTPS vs plain HTTP).
- **TEST-003**: Websocket flag injects upgrade headers.
- **TEST-004**: `doctor`/validation flags duplicate domains, missing `root`, malformed `upstream`, missing required fields.
- **TEST-005**: `generate` is idempotent (twice → no diff) and atomic (interrupted run leaves prior config intact).
- **TEST-006**: Local smoke test: docker+static+host fixtures reachable via `curl` after `up --tls`.
- **TEST-007**: `bootstrap` package-manager detection selects the correct branch on apt/dnf/yum (dry-run/mock).

## 7. Risks & Assumptions

- **RISK-001**: Bash + `yq` templating is fragile vs a typed language — mitigated by isolated generator module, versioned templates, atomic writes, and `doctor`.
- **RISK-002**: `gum` TTY misbehaves under Git Bash/MinTTY — mitigated by mandatory plain-`read` fallback (CON-002).
- **RISK-003**: `host.docker.internal` behavior differs across Docker Desktop vs Linux host-gateway — mitigated via `extra_hosts` and documented per-platform notes.
- **RISK-004**: Let's Encrypt rate limits during testing — mitigated by forced staging outside production/staging (SEC-001).
- **RISK-005**: CRLF line endings corrupting shell scripts on Windows — mitigated by `.gitattributes` LF enforcement (CON-002).
- **ASSUMPTION-001**: One edge instance owns ports 80/443 on the VPS (REQ-007).
- **ASSUMPTION-002**: Each app manages its own internal environment variables; the orchestrator only manages the edge and optional deploy hooks.
- **ASSUMPTION-003**: Target hosts are Linux VPSs using apt/dnf/yum; local dev is Git Bash + Docker Desktop.

## 8. Related Specifications / Further Reading

- `docs/specs/2026-07-09-services-orchestrator-design.md` — approved design spec.
- Reference implementation being generalized: `kontinentalist-orchestrator` (nginx + certbot pattern).
- yq (mikefarah): https://mikefarah.gitbook.io/yq/
- gum (charmbracelet): https://github.com/charmbracelet/gum
- Certbot with nginx + Docker + webroot (Let's Encrypt).
