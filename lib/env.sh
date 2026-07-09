#!/usr/bin/env bash
# lib/env.sh — .env helpers and an interactive editor for secrets/host settings.

: "${ENV_FILE:=.env}"

_env_ensure() {
  if [ ! -f "$ENV_FILE" ] && [ -f "$ROOT_DIR/.env.example" ]; then
    cp "$ROOT_DIR/.env.example" "$ENV_FILE"
    ui_dim "Created .env from .env.example"
  fi
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
}

# _env_get KEY
_env_get() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1
}

# _env_set KEY VALUE  (upsert; preserves other lines)
_env_set() {
  local key="$1" val="$2"
  _env_ensure
  if grep -qE "^$key=" "$ENV_FILE"; then
    # portable in-place: rewrite via temp
    local tmp="$ENV_FILE.tmp.$$"
    awk -v k="$key" -v v="$val" 'BEGIN{FS="="} $1==k{print k"="v; done=1; next} {print} END{if(!done)print k"="v}' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# cmd_env — interactive view/edit loop.
cmd_env() {
  _env_ensure
  while true; do
    ui_title "Current .env"
    grep -vE '^\s*#|^\s*$' "$ENV_FILE" | sed 's/^/  /' || true
    echo
    local choice
    choice="$(ui_choose "What next?" "Edit a value" "Add a new key" "Done")"
    case "$choice" in
      "Edit a value")
        local keys key val
        keys="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$ENV_FILE" | sort -u)"
        [ -z "$keys" ] && { ui_warn "No keys yet."; continue; }
        key="$(ui_choose "Which key?" $keys)"
        val="$(ui_input "New value for $key" "$(_env_get "$key")")"
        _env_set "$key" "$val"; ui_success "Updated $key."
        ;;
      "Add a new key")
        local nk nv
        nk="$(ui_input "New key name")"
        [ -z "$nk" ] && continue
        nv="$(ui_input "Value for $nk")"
        _env_set "$nk" "$nv"; ui_success "Added $nk."
        ;;
      *) break ;;
    esac
  done
}
