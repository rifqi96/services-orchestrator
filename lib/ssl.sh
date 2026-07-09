#!/usr/bin/env bash
# lib/ssl.sh — issue & renew Let's Encrypt certificates for all ssl:true domains.
# Generalizes the original init-letsencrypt into a single `sorch` certificate
# covering every SSL domain, so nginx config always references one cert path.

: "${CERTBOT_DIR:?}"; : "${CERT_NAME:=sorch}"

# _ssl_domains — unique domains across enabled services with ssl: true.
_ssl_domains() {
  local project name ssl domains d
  while IFS= read -r project; do
    [ -z "$project" ] && continue
    [ "$(yaml_project_enabled "$project")" = "true" ] || continue
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      ssl="$(yaml_service_field "$project" "$name" ssl)"
      [ "$ssl" = "true" ] || continue
      domains="$(yaml_service_field "$project" "$name" domains)"
      for d in $domains; do echo "$d"; done
    done < <(yaml_list_services "$project")
  done < <(yaml_list_projects) | sort -u
}

# cmd_ssl — issue/renew certificates.
cmd_ssl() {
  config_validate || return 1
  local env; env="$(yaml_environment)"
  if [ "$env" = "local" ]; then
    ui_error "ssl is for production/staging. For local HTTPS use: ./orchestrator up --tls"
    return 1
  fi

  local domains=()
  while IFS= read -r d; do [ -n "$d" ] && domains+=("$d"); done < <(_ssl_domains)
  if [ ${#domains[@]} -eq 0 ]; then
    ui_warn "No ssl:true services found — nothing to issue."
    return 0
  fi

  local email; email="$(yaml_default certbot_email)"
  local rsa=4096
  local conf="$CERTBOT_DIR/conf"

  # Staging unless production/staging env; .env CERTBOT_STAGING=0 forces real.
  local staging=1
  case "$env" in production|staging) staging=0 ;; esac
  [ "${CERTBOT_STAGING:-}" = "0" ] && staging=0

  ui_title "Issuing certificate '$CERT_NAME' for ${#domains[@]} domain(s)"
  printf '  %s\n' "${domains[@]}"
  [ "$staging" = "1" ] && ui_warn "Using Let's Encrypt STAGING (test certs). Set ENVIRONMENT=production for real certs."

  # 1. Ensure HTTP-only config is live so the ACME challenge is reachable.
  cmd_generate >/dev/null
  compose up -d nginx
  ui_info "Waiting for nginx..."
  _wait_nginx || { ui_error "nginx did not start"; return 1; }

  # 2. Recommended TLS params (used by generated https blocks).
  if [ ! -f "$conf/options-ssl-nginx.conf" ] || [ ! -f "$conf/ssl-dhparams.pem" ]; then
    ui_info "Downloading recommended TLS parameters..."
    mkdir -p "$conf"
    _fetch "https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf" "$conf/options-ssl-nginx.conf"
    _fetch "https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem" "$conf/ssl-dhparams.pem"
  fi

  # 3. Dummy cert so nginx can load an https block if needed during issuance.
  local live="/etc/letsencrypt/live/$CERT_NAME"
  ui_info "Creating placeholder certificate..."
  compose run --rm --entrypoint "\
    sh -c 'mkdir -p $live && openssl req -x509 -nodes -newkey rsa:$rsa -days 1 \
      -keyout $live/privkey.pem -out $live/fullchain.pem -subj /CN=localhost'" certbot

  # 4. Remove placeholder, request the real certificate.
  ui_info "Requesting Let's Encrypt certificate..."
  local domain_args=""
  local d2; for d2 in "${domains[@]}"; do domain_args="$domain_args -d $d2"; done
  local email_arg="--register-unsafely-without-email"
  [ -n "$email" ] && email_arg="--email $email"
  local staging_arg=""
  [ "$staging" = "1" ] && staging_arg="--staging"

  compose run --rm --entrypoint "\
    sh -c 'rm -rf /etc/letsencrypt/live/$CERT_NAME /etc/letsencrypt/archive/$CERT_NAME /etc/letsencrypt/renewal/$CERT_NAME.conf; \
      certbot certonly --webroot -w /var/www/certbot \
      --cert-name $CERT_NAME $staging_arg $email_arg $domain_args \
      --rsa-key-size $rsa --agree-tos --no-eff-email --force-renewal'" certbot

  if [ ! -f "$conf/live/$CERT_NAME/fullchain.pem" ]; then
    ui_error "Certificate issuance failed. Check DNS points to this host and ports 80/443 are open."
    return 1
  fi

  # 5. Regenerate (cert now exists -> full https blocks) and reload.
  ui_info "Enabling HTTPS configuration..."
  cmd_generate >/dev/null
  compose exec -T nginx nginx -s reload 2>/dev/null || compose up -d --force-recreate nginx
  ui_success "SSL ready for ${#domains[@]} domain(s)."
}

# cmd_ssl_renew — used by the cron script: renew then reload nginx.
cmd_ssl_renew() {
  compose run --rm certbot renew
  compose exec -T nginx nginx -s reload 2>/dev/null || true
  ui_success "Renewal check complete."
}

_wait_nginx() {
  local name="${COMPOSE_PROJECT_NAME:-sorch}-nginx" i=0
  while [ $i -lt 30 ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

_fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$out"
  else wget -qO "$out" "$url"; fi
}
