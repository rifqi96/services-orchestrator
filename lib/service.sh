#!/usr/bin/env bash
# lib/service.sh — interactive management of services.yml.
#   service add | edit | remove | list

# enumerate "project/name" for every service (one per line)
_service_index() {
  local project name
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "$project/$name"
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects)
}

# validate + persist; revert from backup if the edit made the file invalid.
_service_commit() {
  if config_validate >/dev/null 2>&1; then
    if [ -f "$SERVICES_FILE.bak" ]; then :; fi
    cmd_generate >/dev/null 2>&1 || true
    ui_success "Saved and regenerated nginx config."
    return 0
  fi
  ui_error "That change is invalid — reverting."
  config_validate   # re-run to print the reasons
  [ -f "$SERVICES_FILE.bak" ] && cp "$SERVICES_FILE.bak" "$SERVICES_FILE"
  return 1
}

# normalize a host upstream: "8000" or ":8000" -> "127.0.0.1:8000"
_normalize_host_upstream() {
  local u="$1"
  case "$u" in
    :*)      echo "127.0.0.1$u" ;;
    *:*)     echo "$u" ;;
    *[!0-9]*) echo "$u" ;;               # not a bare number; leave as-is
    *)       echo "127.0.0.1:$u" ;;      # bare number -> localhost:port
  esac
}

cmd_service() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)    _service_add "$@" ;;
    edit)   _service_edit "$@" ;;
    remove|rm) _service_remove "$@" ;;
    list|ls) _service_list "$@" ;;
    "")     ui_error "Usage: ./orchestrator service <add|edit|remove|list>" ; return 1 ;;
    *)      ui_error "Unknown: service $sub" ; return 1 ;;
  esac
}

_service_add() {
  config_require || return 1

  # project
  local project projects
  projects="$(yaml_list_projects)"
  if [ -n "$projects" ]; then
    project="$(ui_choose "Project" $projects "＋ New project")"
    if [ "$project" = "＋ New project" ]; then project="$(ui_input "New project name")"; fi
  else
    project="$(ui_input "Project name" "default")"
  fi
  [ -z "$project" ] && { ui_error "Project name required."; return 1; }

  local name type domains upstream="" root="" ssl ws="false" deploy="" networks=""
  name="$(ui_input "Service name")"
  [ -z "$name" ] && { ui_error "Service name required."; return 1; }
  # uniqueness
  if yaml_list_services "$project" | grep -Fxq "$name"; then
    ui_error "Service '$name' already exists in project '$project'."; return 1
  fi

  type="$(ui_choose "Type" docker host static)"
  domains="$(ui_input "Domain(s) (space/comma separated)")"
  [ -z "$domains" ] && { ui_error "At least one domain required."; return 1; }
  domains="${domains// /,}"

  case "$type" in
    docker)
      ui_dim "Use the container's INTERNAL port (not the host-published one), e.g. app:80."
      upstream="$(ui_input "Upstream container:port" "app:80")"
      ui_dim "nginx must share the app's Docker network (see: docker network ls)."
      networks="$(ui_input "Docker network(s) to join (comma sep)")"
      networks="${networks// /,}"
      [ -z "$networks" ] && ui_warn "No network set — nginx likely cannot reach a docker upstream. Consider type 'host' with the published port instead."
      ui_confirm "Does this service use websockets?" && ws="true"
      ;;
    host)
      upstream="$(ui_input "Host port or host:port" "8000")"
      upstream="$(_normalize_host_upstream "$upstream")"
      ui_confirm "Does this service use websockets?" && ws="true"
      ;;
    static)
      root="$(ui_input "Static root directory (served by nginx)" "/var/www/$name/dist")"
      ;;
  esac

  ssl="false"; ui_confirm "Enable HTTPS/SSL for this service?" && ssl="true"
  deploy="$(ui_input "Optional deploy hook command (blank = none)")"

  config_backup
  yaml_add_service "$project" "$name" "$type" "$domains" "$upstream" "$root" "$ssl" "$ws" "$deploy" "$networks"
  _service_commit && ui_info "Added $project/$name ($type)."
}

_service_edit() {
  config_require || return 1
  local pick project name
  pick="$(_service_index)"
  [ -z "$pick" ] && { ui_warn "No services yet. Use: service add"; return 0; }
  local target; target="$(ui_choose "Edit which service?" $pick)"
  [ -z "$target" ] && return 0
  project="${target%%/*}"; name="${target##*/}"
  local type; type="$(yaml_service_field "$project" "$name" type)"

  local field; field="$(ui_choose "Edit field" type domains upstream root ssl websocket deploy networks)"
  config_backup
  case "$field" in
    type)
      local nt; nt="$(ui_choose "New type" docker host static)"
      yaml_set_service_field "$project" "$name" type "$nt"
      case "$nt" in
        docker)
          local u nw
          ui_dim "Use the container's INTERNAL port, e.g. app:80."
          u="$(ui_input "Upstream container:port" "$(yaml_service_field "$project" "$name" upstream)")"
          yaml_set_service_field "$project" "$name" upstream "$u"
          nw="$(ui_input "Docker network(s) (comma sep)" "$(yaml_service_field "$project" "$name" networks)")"; nw="${nw// /,}"
          yaml_set_service_field "$project" "$name" networks "$(_csv_to_json_array "$nw")" --json
          ;;
        host)
          local u; u="$(ui_input "Host port or host:port" "$(yaml_service_field "$project" "$name" upstream)")"
          yaml_set_service_field "$project" "$name" upstream "$(_normalize_host_upstream "$u")"
          yaml_set_service_field "$project" "$name" networks "[]" --json
          ;;
        static)
          local r; r="$(ui_input "Static root" "$(yaml_service_field "$project" "$name" root)")"
          yaml_set_service_field "$project" "$name" root "$r"
          ;;
      esac
      ;;
    domains)
      local v; v="$(ui_input "Domains (space/comma separated)" "$(yaml_service_field "$project" "$name" domains)")"
      v="${v// /,}"
      yaml_set_service_field "$project" "$name" domains "$(_csv_to_json_array "$v")" --json
      ;;
    networks)
      local v; v="$(ui_input "Networks (comma separated)" "$(yaml_service_field "$project" "$name" networks)")"
      v="${v// /,}"
      yaml_set_service_field "$project" "$name" networks "$(_csv_to_json_array "$v")" --json
      ;;
    upstream)
      local v; v="$(ui_input "Upstream" "$(yaml_service_field "$project" "$name" upstream)")"
      [ "$type" = "host" ] && v="$(_normalize_host_upstream "$v")"
      yaml_set_service_field "$project" "$name" upstream "$v"
      ;;
    root)
      local v; v="$(ui_input "Static root" "$(yaml_service_field "$project" "$name" root)")"
      yaml_set_service_field "$project" "$name" root "$v"
      ;;
    deploy)
      local v; v="$(ui_input "Deploy hook (blank = none)" "$(yaml_service_field "$project" "$name" deploy)")"
      yaml_set_service_field "$project" "$name" deploy "$v"
      ;;
    ssl)
      local v="false"; ui_confirm "Enable SSL?" && v="true"
      yaml_set_service_field "$project" "$name" ssl "$v" --bool
      ;;
    websocket)
      local v="false"; ui_confirm "Enable websockets?" && v="true"
      yaml_set_service_field "$project" "$name" websocket "$v" --bool
      ;;
  esac
  _service_commit && ui_info "Updated $project/$name."
}

_service_remove() {
  config_require || return 1
  local pick; pick="$(_service_index)"
  [ -z "$pick" ] && { ui_warn "No services to remove."; return 0; }
  local target; target="$(ui_choose "Remove which service?" $pick)"
  [ -z "$target" ] && return 0
  local project="${target%%/*}" name="${target##*/}"
  ui_confirm "Really remove $project/$name?" || { ui_dim "Cancelled."; return 0; }
  config_backup
  yaml_remove_service "$project" "$name"
  _service_commit && ui_info "Removed $project/$name."
}

_service_list() {
  config_require || return 1
  local project name type domains ssl target
  local any=0
  ui_title "Configured services"
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    local en; en="$(yaml_project_enabled "$project")"
    printf '\n%s%s%s%s\n' "$C_BOLD" "$project" "$C_RESET" "$([ "$en" = "true" ] && echo "" || echo " ${C_DIM}(disabled)${C_RESET}")"
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      any=1
      type="$(yaml_service_field "$project" "$name" type)"
      domains="$(yaml_service_field "$project" "$name" domains)"
      ssl="$(yaml_service_field "$project" "$name" ssl)"
      if [ "$type" = "static" ]; then
        target="root:$(yaml_service_field "$project" "$name" root)"
      else
        target="$(yaml_service_field "$project" "$name" upstream)"
      fi
      printf '  %-16s %-7s ssl=%-5s %-22s %s\n' "$name" "$type" "$ssl" "$target" "$domains"
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects)
  [ "$any" = 0 ] && ui_dim "  (none yet — add one with: service add)"
}
