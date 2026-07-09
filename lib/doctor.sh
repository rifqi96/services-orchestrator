#!/usr/bin/env bash
# lib/doctor.sh — preflight & health checks.
#   doctor          full checks (deps, config, ports, networks)
#   doctor --pre    lightweight gate used before up/deploy (deps + config)

_port_in_use() {
  local p="$1"
  if has_cmd ss; then ss -ltn 2>/dev/null | grep -q ":$p "
  elif has_cmd lsof; then lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  elif has_cmd netstat; then netstat -ltn 2>/dev/null | grep -q ":$p "
  else return 1; fi
}

# is our own nginx already bound to the port?
_our_nginx_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${COMPOSE_PROJECT_NAME:-sorch}-nginx$"
}

cmd_doctor() {
  local pre=0; [ "${1:-}" = "--pre" ] && pre=1
  local errors=0 warns=0

  # --- dependencies ---------------------------------------------------------
  local miss; miss="$(deps_missing docker compose yq)"
  if [ -n "$miss" ]; then
    ui_error "Missing dependencies: $(echo "$miss" | tr '\n' ' ')(run: ./orchestrator bootstrap)"
    errors=$((errors+1))
  fi
  has_cmd gum || { [ "$pre" = 1 ] || { ui_warn "gum not installed (interactive menus fall back to plain prompts)."; warns=$((warns+1)); }; }

  # --- config ---------------------------------------------------------------
  if [ -f "$SERVICES_FILE" ]; then
    if config_validate; then
      [ "$pre" = 1 ] || ui_success "services.yml is valid."
    else
      errors=$((errors+1))
    fi
  else
    ui_error "No services.yml (run: ./orchestrator init)"
    errors=$((errors+1))
  fi

  if [ "$pre" = 1 ]; then
    [ "$errors" -gt 0 ] && return 1 || return 0
  fi

  # --- ports ----------------------------------------------------------------
  if _our_nginx_running; then
    ui_dim "Edge already running (ports 80/443 held by our nginx)."
  else
    local p
    for p in 80 443; do
      if _port_in_use "$p"; then
        ui_warn "Port $p is already in use by another process."
        warns=$((warns+1))
      fi
    done
  fi

  # --- docker networks ------------------------------------------------------
  if [ -s "$NETWORKS_FILE" ] && has_cmd docker; then
    local n
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      if ! docker network inspect "$n" >/dev/null 2>&1; then
        ui_dim "network '$n' missing — will be created on 'up'."
      fi
    done < "$NETWORKS_FILE"
  fi

  # --- static roots ---------------------------------------------------------
  local project name type root
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      type="$(yaml_service_field "$project" "$name" type)"
      [ "$type" = "static" ] || continue
      root="$(yaml_service_field "$project" "$name" root)"
      if [ -n "$root" ] && [ ! -d "$root" ]; then
        ui_warn "$project/$name: static root '$root' not found on host (mount it into nginx before serving)."
        warns=$((warns+1))
      fi
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects)

  echo
  if [ "$errors" -gt 0 ]; then
    ui_error "doctor: $errors error(s), $warns warning(s)."
    return 1
  fi
  ui_success "doctor: healthy${warns:+ ($warns warning(s))}."
  return 0
}
