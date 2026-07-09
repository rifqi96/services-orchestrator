#!/usr/bin/env bash
# lib/generate.sh — render nginx config from services.yml.
# Idempotent + atomic: renders into $CONF_TMP, then swaps into $CONF_D. Only
# ENABLED projects/services produce files (this removes the Dockerfile deletion
# hack of the original orchestrator).

: "${CONF_D:?}"; : "${CONF_TMP:?}"; : "${TEMPLATES_DIR:?}"; : "${NETWORKS_FILE:?}"
: "${CERT_NAME:=sorch}"
: "${NGINX_DIR:?}"
: "${CERTBOT_LIVE:=$NGINX_DIR/certbot/conf/live}"
: "${COMPOSE_NET_FILE:=$NGINX_DIR/../docker-compose.networks.yml}"

# True if the Let's Encrypt (or mkcert) certificate is already present.
_cert_exists() { [ -f "$CERTBOT_LIVE/$CERT_NAME/fullchain.pem" ]; }

# Standard proxy headers (shared by docker & host).
_proxy_headers() {
  cat <<'EOF'
    proxy_set_header Host              $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
EOF
}

_websocket_headers() {
  cat <<'EOF'
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_cache_bypass $http_upgrade;
    proxy_read_timeout 90;
EOF
}

# _build_location <type> <upstream> <root> <websocket>
_build_location() {
  local type="$1" upstream="$2" root="$3" ws="$4"
  case "$type" in
    docker|host)
      local target="$upstream"
      [ "$type" = "host" ] && target="host.docker.internal:${upstream##*:}"
      echo "  location / {"
      echo "    proxy_pass http://${target};"
      _proxy_headers
      [ "$ws" = "true" ] && _websocket_headers
      echo "  }"
      ;;
    static)
      echo "  location / {"
      echo "    root ${root};"
      echo "    try_files \$uri \$uri/ =404;"
      echo "  }"
      ;;
  esac
}

# _render <template-name> using globals SERVER_NAME/CERT_NAME/SSL_INCLUDES/LOCATION_BLOCK
_render() {
  local tmpl="$TEMPLATES_DIR/$1"
  SERVER_NAME="$SERVER_NAME" CERT_NAME="$CERT_NAME" \
  SSL_INCLUDES="$SSL_INCLUDES" LOCATION_BLOCK="$LOCATION_BLOCK" \
    envsubst '${SERVER_NAME} ${CERT_NAME} ${SSL_INCLUDES} ${LOCATION_BLOCK}' < "$tmpl"
}

# cmd_generate [--tls]
cmd_generate() {
  local local_tls=0
  for a in "$@"; do [ "$a" = "--tls" ] && local_tls=1; done

  config_validate || return 1

  local env; env="$(yaml_environment)"
  local is_prod=0
  case "$env" in production|staging) is_prod=1 ;; esac

  local ssl_includes_prod="  include /etc/letsencrypt/options-ssl-nginx.conf;
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
"

  rm -rf "$CONF_TMP"; mkdir -p "$CONF_TMP"
  : > "$NETWORKS_FILE.tmp"

  local project name type upstream root ssl ws domains netlist out n
  local count=0

  while IFS= read -r project; do
    [ -z "$project" ] && continue
    if [ "$(yaml_project_enabled "$project")" != "true" ]; then
      ui_dim "skip disabled project: $project"; continue
    fi
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      type="$(yaml_service_field "$project" "$name" type)"
      upstream="$(yaml_service_field "$project" "$name" upstream)"
      root="$(yaml_service_field "$project" "$name" root)"
      ssl="$(yaml_service_field "$project" "$name" ssl)"
      ws="$(yaml_service_field "$project" "$name" websocket)"
      domains="$(yaml_service_field "$project" "$name" domains)"
      netlist="$(yaml_service_field "$project" "$name" networks)"

      SERVER_NAME="$domains"
      LOCATION_BLOCK="$(_build_location "$type" "$upstream" "$root" "$ws")"
      out="$CONF_TMP/${project}-${name}.conf"

      if [ "$is_prod" = "1" ]; then
        if [ "$ssl" = "true" ] && _cert_exists; then
          SSL_INCLUDES="$ssl_includes_prod"
          { _render http-redirect.conf.tmpl; echo; _render https.conf.tmpl; } > "$out"
        elif [ "$ssl" = "true" ]; then
          SSL_INCLUDES=""
          _render http-only.conf.tmpl > "$out"
          ui_warn "${project}/${name}: no cert yet for '$CERT_NAME' — serving HTTP until you run: ./orchestrator ssl"
        else
          SSL_INCLUDES=""
          _render http-only.conf.tmpl > "$out"
        fi
      else
        if [ "$local_tls" = "1" ] && [ "$ssl" = "true" ]; then
          SSL_INCLUDES=""
          { _render http-only.conf.tmpl; echo; _render https.conf.tmpl; } > "$out"
        else
          SSL_INCLUDES=""
          _render http-only.conf.tmpl > "$out"
        fi
      fi

      if [ "$type" = "docker" ] && [ -n "$netlist" ]; then
        for n in $netlist; do echo "$n" >> "$NETWORKS_FILE.tmp"; done
      fi

      count=$((count+1))
      ui_dim "rendered ${project}-${name}.conf (${type}, ssl=${ssl})"
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects)

  [ "$count" -eq 0 ] && ui_warn "No enabled services to render."

  # swap in new configs. Keep the conf.d directory inode intact so a running
  # nginx bind-mount stays valid (nginx only applies changes on reload).
  mkdir -p "$CONF_D"; touch "$CONF_D/.gitkeep"
  rm -f "$CONF_D"/*.conf 2>/dev/null || true
  if ls "$CONF_TMP"/*.conf >/dev/null 2>&1; then cp "$CONF_TMP"/*.conf "$CONF_D"/; fi
  rm -rf "$CONF_TMP"

  if [ -f "$NETWORKS_FILE.tmp" ]; then
    sort -u "$NETWORKS_FILE.tmp" > "$NETWORKS_FILE"; rm -f "$NETWORKS_FILE.tmp"
  else
    : > "$NETWORKS_FILE"
  fi

  _write_compose_networks
  ui_success "Generated $count service config(s) into nginx/conf.d/"
}

# _write_compose_networks — Compose override attaching nginx to external nets.
_write_compose_networks() {
  local nets=() n
  if [ -s "$NETWORKS_FILE" ]; then
    while IFS= read -r n; do [ -n "$n" ] && nets+=("$n"); done < "$NETWORKS_FILE"
  fi
  {
    echo "# GENERATED by orchestrator — do not edit."
    echo "services:"
    echo "  nginx:"
    echo "    networks:"
    echo "      - default"
    for n in "${nets[@]}"; do echo "      - $n"; done
    if [ ${#nets[@]} -gt 0 ]; then
      echo "networks:"
      for n in "${nets[@]}"; do
        echo "  $n:"
        echo "    external: true"
      done
    fi
  } > "$COMPOSE_NET_FILE"
}
