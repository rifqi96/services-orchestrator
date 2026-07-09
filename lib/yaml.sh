#!/usr/bin/env bash
# lib/yaml.sh — thin, purpose-built helpers over `yq` (mikefarah v4) for
# reading and writing services.yml. All functions operate on $SERVICES_FILE.

: "${SERVICES_FILE:=services.yml}"

_yq() { yq "$@"; }

# convert "a,b, c" -> '["a","b","c"]' (empty -> '[]')
_csv_to_json_array() {
  local csv="$1"
  csv="${csv//,/ }"
  local out="[" first=1 item
  for item in $csv; do
    if [ $first -eq 1 ]; then first=0; else out="${out},"; fi
    out="${out}\"${item}\""
  done
  out="${out}]"
  printf '%s' "$out"
}

# --- reads ------------------------------------------------------------------

# yaml_get <yq-expression>  -> prints result ("null" if absent)
yaml_get() { _yq eval "$1" "$SERVICES_FILE"; }

yaml_default() { _yq eval ".defaults.$1 // \"\"" "$SERVICES_FILE"; }

# environment resolved from services.yml defaults (falls back to production).
yaml_environment() {
  local env; env="$(yaml_default environment)"
  printf '%s' "${env:-production}"
}

# list all project names (one per line)
yaml_list_projects() {
  _yq eval '.projects | keys | .[]' "$SERVICES_FILE" 2>/dev/null
}

# yaml_project_enabled <project> -> "true"/"false" (missing => true)
yaml_project_enabled() {
  _yq eval ".projects.\"$1\".enabled // true" "$SERVICES_FILE"
}

# list service names within a project (one per line)
yaml_list_services() {
  local project="$1"
  _yq eval ".projects.\"$project\".services[].name" "$SERVICES_FILE" 2>/dev/null
}

# number of services in a project
yaml_service_count() {
  local project="$1"
  _yq eval ".projects.\"$project\".services | length" "$SERVICES_FILE" 2>/dev/null
}

# yaml_service_field <project> <service-name> <field>
# fields: domains (space-joined), type, upstream, root, ssl, websocket, deploy,
#         networks (space-joined)
yaml_service_field() {
  local project="$1" name="$2" field="$3"
  local base=".projects.\"$project\".services[] | select(.name == \"$name\")"
  case "$field" in
    domains|networks)
      _yq eval "[$base | .$field // [] | .[]] | join(\" \")" "$SERVICES_FILE" 2>/dev/null
      ;;
    ssl|websocket)
      # boolean fields: default to false. `//` treats false as "use RHS", so the
      # default MUST be false (not "") to preserve an explicit false.
      _yq eval "$base | (.$field // false)" "$SERVICES_FILE" 2>/dev/null
      ;;
    *)
      _yq eval "$base | .$field // \"\"" "$SERVICES_FILE" 2>/dev/null
      ;;
  esac
}

# --- writes (caller is responsible for backup + validation) -----------------

# yaml_ensure_project <project> [enabled]
yaml_ensure_project() {
  local project="$1" enabled="${2:-true}"
  _yq eval -i "
    .projects.\"$project\".enabled = (.projects.\"$project\".enabled // $enabled) |
    .projects.\"$project\".services = (.projects.\"$project\".services // [])
  " "$SERVICES_FILE"
}

# yaml_set_project_enabled <project> <true|false>
yaml_set_project_enabled() {
  _yq eval -i ".projects.\"$1\".enabled = $2" "$SERVICES_FILE"
}

# yaml_add_service <project> <name> <type> <domains-csv> <upstream> <root> \
#                  <ssl> <websocket> <deploy> <networks-csv>
# Appends a new service object. domains/networks are comma-separated.
yaml_add_service() {
  local project="$1" name="$2" type="$3" domains="$4" upstream="$5" root="$6"
  local ssl="$7" websocket="$8" deploy="$9" networks="${10}"
  yaml_ensure_project "$project" true
  local dom_json net_json
  dom_json="$(_csv_to_json_array "$domains")"
  net_json="$(_csv_to_json_array "$networks")"
  SVC_NAME="$name" SVC_TYPE="$type" SVC_UP="$upstream" SVC_ROOT="$root" \
  SVC_SSL="$ssl" SVC_WS="$websocket" SVC_DEPLOY="$deploy" \
  SVC_DOM="$dom_json" SVC_NET="$net_json" \
  _yq eval -i "
    .projects.\"$project\".services += [{
      \"name\": strenv(SVC_NAME),
      \"domains\": (strenv(SVC_DOM) | fromjson),
      \"type\": strenv(SVC_TYPE),
      \"upstream\": strenv(SVC_UP),
      \"root\": strenv(SVC_ROOT),
      \"ssl\": (strenv(SVC_SSL) == \"true\"),
      \"websocket\": (strenv(SVC_WS) == \"true\"),
      \"deploy\": strenv(SVC_DEPLOY),
      \"networks\": (strenv(SVC_NET) | fromjson)
    }]
  " "$SERVICES_FILE"
}

# yaml_set_service_field <project> <name> <field> <value> [--json|--bool]
yaml_set_service_field() {
  local project="$1" name="$2" field="$3" value="$4" mode="${5:-}"
  if [ "$mode" = "--json" ]; then
    YQ_VAL="$value" _yq eval -i \
      ".projects.\"$project\".services[] |= (select(.name == \"$name\").$field = (strenv(YQ_VAL) | fromjson))" \
      "$SERVICES_FILE"
  elif [ "$mode" = "--bool" ]; then
    _yq eval -i \
      ".projects.\"$project\".services[] |= (select(.name == \"$name\").$field = ($value))" \
      "$SERVICES_FILE"
  else
    YQ_VAL="$value" _yq eval -i \
      ".projects.\"$project\".services[] |= (select(.name == \"$name\").$field = strenv(YQ_VAL))" \
      "$SERVICES_FILE"
  fi
}

# yaml_remove_service <project> <name>
yaml_remove_service() {
  local project="$1" name="$2"
  _yq eval -i \
    "del(.projects.\"$project\".services[] | select(.name == \"$name\"))" \
    "$SERVICES_FILE"
  local cnt; cnt="$(yaml_service_count "$project")"
  if [ "${cnt:-0}" -eq 0 ]; then
    _yq eval -i "del(.projects.\"$project\")" "$SERVICES_FILE"
  fi
}
