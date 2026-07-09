#!/usr/bin/env bash
# lib/hosts.sh — print /etc/hosts lines for local-mode domains so browser
# requests to your service domains resolve to localhost.

cmd_hosts() {
  config_require || return 1
  local project name domains d seen=""
  ui_title "Add these lines to your hosts file for local testing"
  ui_dim "Linux/macOS: /etc/hosts   •   Windows: C:\\Windows\\System32\\drivers\\etc\\hosts"
  echo
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      domains="$(yaml_service_field "$project" "$name" domains)"
      for d in $domains; do
        case "$seen" in *" $d "*) continue ;; esac
        seen="$seen $d "
        printf '127.0.0.1\t%s\n' "$d"
      done
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects)
}
