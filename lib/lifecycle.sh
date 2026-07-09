#!/usr/bin/env bash
# lib/lifecycle.sh — up / down / deploy. The edge is a single shared nginx, so
# up/down operate on the whole edge; `deploy [project...]` scopes which deploy
# hooks run before bringing the edge up.

_need_docker() {
  if ! has_cmd docker; then ui_error "docker not found. Run: ./orchestrator bootstrap"; return 1; fi
  if ! has_docker_compose; then ui_error "docker compose v2 not found. Run: ./orchestrator bootstrap"; return 1; fi
  if ! docker info >/dev/null 2>&1; then ui_error "Docker daemon not reachable. Is Docker running?"; return 1; fi
}

_in() { local needle="$1"; shift; local x; for x in "$@"; do [ "$x" = "$needle" ] && return 0; done; return 1; }

# create every external network referenced by docker services (idempotent).
_create_networks() {
  [ -s "$NETWORKS_FILE" ] || return 0
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    docker network inspect "$n" >/dev/null 2>&1 || docker network create "$n" >/dev/null 2>&1 \
      && ui_dim "network ready: $n"
  done < "$NETWORKS_FILE"
}

_maybe_cron() {
  local env; env="$(yaml_environment)"
  case "$env" in production|staging) cron_install ;; esac
}

# cmd_up [--tls] [--force]
cmd_up() {
  local tls="" force=0 extra=()
  for a in "$@"; do
    case "$a" in
      --tls)   tls="--tls" ;;
      --force) force=1 ;;
      *)       extra+=("$a") ;;
    esac
  done
  [ ${#extra[@]} -gt 0 ] && ui_warn "The edge is shared; project scope is ignored for 'up' (use it with 'deploy'). Bringing up all enabled services."

  config_require || return 1
  _need_docker || return 1

  if [ -n "$tls" ]; then _local_tls_setup || return 1; fi

  if ! cmd_doctor --pre; then
    [ "$force" = 1 ] || { ui_error "Preflight failed. Fix the issues above or use: up --force"; return 1; }
    ui_warn "Continuing despite preflight failures (--force)."
  fi

  cmd_generate $tls || return 1
  _create_networks
  ui_info "Starting edge..."
  compose up -d || return 1
  _maybe_cron
  ui_success "Edge is up (nginx on :80${tls:+ and :443})."
}

# cmd_down [--volumes]
cmd_down() {
  _need_docker || return 1
  ui_info "Stopping edge..."
  compose down "$@"
  local env; env="$(yaml_environment 2>/dev/null || echo production)"
  case "$env" in production|staging) cron_remove ;; esac
  ui_success "Edge stopped."
}

# cmd_deploy [project...] — run deploy hooks (scoped) then bring up the edge.
cmd_deploy() {
  config_require || return 1
  _need_docker || return 1
  local scope=("$@")

  local project name hook ran=0
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    [ "$(yaml_project_enabled "$project")" = "true" ] || continue
    if [ ${#scope[@]} -gt 0 ] && ! _in "$project" "${scope[@]}"; then continue; fi
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      hook="$(yaml_service_field "$project" "$name" deploy)"
      [ -z "$hook" ] || [ "$hook" = "null" ] && continue
      ui_title "deploy hook: $project/$name"
      ui_dim "\$ $hook"
      if ( cd "$ROOT_DIR" && bash -c "$hook" ); then
        ui_success "$project/$name deployed."
        ran=$((ran+1))
      else
        ui_error "Deploy hook FAILED for $project/$name — stopping."
        return 1
      fi
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects)

  [ "$ran" -eq 0 ] && ui_dim "No deploy hooks to run."

  cmd_generate || return 1
  _create_networks
  ui_info "Bringing edge up..."
  compose up -d || return 1
  ui_success "Deploy complete."
}

# _local_tls_setup — generate self-signed certs with mkcert for local HTTPS.
_local_tls_setup() {
  local env; env="$(yaml_environment)"
  if [ "$env" != "local" ]; then
    ui_error "--tls is only for environment: local. Use './orchestrator ssl' for real certs."
    return 1
  fi
  if ! has_cmd mkcert; then
    ui_error "mkcert not found. Run: ./orchestrator bootstrap"
    return 1
  fi
  local dir="$CERTBOT_LIVE/$CERT_NAME"
  mkdir -p "$dir"
  local domains=()
  while IFS= read -r d; do [ -n "$d" ] && domains+=("$d"); done < <(_ssl_domains)
  if [ ${#domains[@]} -eq 0 ]; then
    ui_warn "No ssl:true services; nothing to make certs for."
    return 0
  fi
  ui_info "Generating local certificate for: ${domains[*]}"
  mkcert -install >/dev/null 2>&1 || true
  mkcert -cert-file "$dir/fullchain.pem" -key-file "$dir/privkey.pem" "${domains[@]}" >/dev/null 2>&1
  chmod 600 "$dir/privkey.pem" 2>/dev/null || true
  ui_success "Local certificate ready ($CERT_NAME)."
}
