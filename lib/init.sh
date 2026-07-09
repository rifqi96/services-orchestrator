#!/usr/bin/env bash
# lib/init.sh — first-run setup: create services.yml + .env and set defaults.

cmd_init() {
  ui_title "services-orchestrator setup"

  local email env
  email="$(ui_input "Email for Let's Encrypt (certbot)" "$(yaml_default certbot_email 2>/dev/null || echo you@example.com)")"
  env="$(ui_choose "Environment" production staging local)"

  if [ ! -f "$SERVICES_FILE" ]; then
    cat > "$SERVICES_FILE" <<EOF
# Managed by 'orchestrator' — edit via: ./orchestrator service add|edit|remove
defaults:
  certbot_email: $email
  environment: $env
projects: {}
EOF
    ui_success "Created services.yml"
  else
    yq eval -i ".defaults.certbot_email = \"$email\" | .defaults.environment = \"$env\"" "$SERVICES_FILE"
    ui_success "Updated services.yml defaults"
  fi

  # keep .env in sync for runtime scripts
  _env_set ENVIRONMENT "$env"
  _env_set CERTBOT_EMAIL "$email"
  [ "$env" = "local" ] && _env_set CERTBOT_STAGING "1"

  echo
  ui_info "Next steps:"
  ui_dim "  1. ./orchestrator service add        # add your first service"
  ui_dim "  2. ./orchestrator up                 # start locally (or 'up --tls')"
  ui_dim "  3. ./orchestrator ssl                # issue certs (production/staging)"
}
