#!/usr/bin/env bash
# lib/config.sh — validation, backup, and safe writes for services.yml.

: "${SERVICES_FILE:=services.yml}"

# config_backup — timestamped copy next to services.yml.
config_backup() {
  [ -f "$SERVICES_FILE" ] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp "$SERVICES_FILE" "${SERVICES_FILE}.${ts}.bak"
  # keep a stable "latest" backup too
  cp "$SERVICES_FILE" "${SERVICES_FILE}.bak"
}

# config_require — services.yml must exist.
config_require() {
  if [ ! -f "$SERVICES_FILE" ]; then
    ui_error "No $SERVICES_FILE found. Run: ./orchestrator init"
    return 1
  fi
}

# config_valid_yaml — parses as YAML.
config_valid_yaml() {
  if ! yq eval '.' "$SERVICES_FILE" >/dev/null 2>&1; then
    ui_error "$SERVICES_FILE is not valid YAML."
    return 1
  fi
}

# config_validate — full semantic validation. Returns non-zero on any error.
# Prints each problem it finds.
config_validate() {
  config_require || return 1
  config_valid_yaml || return 1

  local errors=0
  local seen_domains="" project name type ssl upstream root domains dom

  while IFS= read -r project; do
    [ -z "$project" ] && continue
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      type="$(yaml_service_field "$project" "$name" type)"
      upstream="$(yaml_service_field "$project" "$name" upstream)"
      root="$(yaml_service_field "$project" "$name" root)"
      domains="$(yaml_service_field "$project" "$name" domains)"

      # name present
      if [ -z "$name" ] || [ "$name" = "null" ]; then
        ui_error "[$project] a service is missing a name."; errors=$((errors+1))
      fi

      # type valid
      case "$type" in
        docker|host|static) : ;;
        *) ui_error "[$project/$name] invalid type '$type' (docker|host|static)."; errors=$((errors+1)) ;;
      esac

      # domains present
      if [ -z "$domains" ]; then
        ui_error "[$project/$name] has no domains."; errors=$((errors+1))
      fi

      # type-specific requirements
      case "$type" in
        docker|host)
          if [ -z "$upstream" ] || [ "$upstream" = "null" ]; then
            ui_error "[$project/$name] type '$type' requires an upstream (host:port)."; errors=$((errors+1))
          elif ! printf '%s' "$upstream" | grep -Eq '^[A-Za-z0-9._-]+:[0-9]+$'; then
            ui_error "[$project/$name] upstream '$upstream' must be host:port."; errors=$((errors+1))
          fi
          ;;
        static)
          if [ -z "$root" ] || [ "$root" = "null" ]; then
            ui_error "[$project/$name] type 'static' requires a root path."; errors=$((errors+1))
          fi
          ;;
      esac

      # duplicate domain detection (across all projects/services)
      for dom in $domains; do
        if printf '%s\n' "$seen_domains" | grep -Fxq "$dom"; then
          ui_error "duplicate domain '$dom' (also used by another service)."; errors=$((errors+1))
        else
          seen_domains="${seen_domains}${dom}"$'\n'
        fi
      done
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects)

  if [ "$errors" -gt 0 ]; then
    ui_error "Validation failed with $errors problem(s)."
    return 1
  fi
  return 0
}

# config_atomic_write <tmpfile> — validate a candidate file, then move into place.
# Backs up the current file first.
config_atomic_write() {
  local tmp="$1"
  local orig="$SERVICES_FILE"
  # validate the candidate by pointing SERVICES_FILE at it
  local prev="$SERVICES_FILE"
  SERVICES_FILE="$tmp"
  if ! config_validate; then
    SERVICES_FILE="$prev"
    rm -f "$tmp"
    return 1
  fi
  SERVICES_FILE="$prev"
  config_backup
  mv "$tmp" "$orig"
}
