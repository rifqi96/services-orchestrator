#!/usr/bin/env bash
# tests/nginx-validate.sh — validate the GENERATED nginx config against real
# nginx using a throwaway container. Requires Docker. No ports are bound.
# Usage: bash tests/nginx-validate.sh
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not installed"; exit 0; }
docker info >/dev/null 2>&1 || { echo "SKIP: docker daemon not running"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/nginx/conf.d" "$WORK/templates"
cp "$ROOT_DIR"/templates/*.tmpl "$WORK/templates/"

export TEMPLATES_DIR="$WORK/templates" CONF_D="$WORK/nginx/conf.d" \
  CONF_TMP="$WORK/nginx/.conf.d.tmp" NETWORKS_FILE="$WORK/nginx/.networks" \
  NGINX_DIR="$WORK/nginx" CERTBOT_LIVE="$WORK/nginx/certbot/conf/live" \
  COMPOSE_NET_FILE="$WORK/docker-compose.networks.yml" CERT_NAME="sorch" \
  SERVICES_FILE="$WORK/services.yml"

source "$ROOT_DIR/lib/ui.sh"; for f in dim success warn info; do eval "ui_$f(){ :; }"; done
source "$ROOT_DIR/lib/deps.sh"; source "$ROOT_DIR/lib/yaml.sh"
source "$ROOT_DIR/lib/config.sh"; source "$ROOT_DIR/lib/generate.sh"

cat > "$SERVICES_FILE" <<YML
defaults: { environment: local, certbot_email: t@example.com }
projects:
  demo:
    enabled: true
    services:
      - { name: app,  domains: [app.local],           type: docker, upstream: app-web:3000, root: "",             ssl: true,  websocket: true,  deploy: "", networks: [appnet] }
      - { name: api,  domains: [api.local],           type: host,   upstream: 127.0.0.1:9000, root: "",            ssl: false, websocket: false, deploy: "", networks: [] }
      - { name: site, domains: [site.local, w.local], type: static, upstream: "",             root: /usr/share/nginx/html, ssl: false, websocket: false, deploy: "", networks: [] }
YML

echo "Generating config (local)..."; cmd_generate >/dev/null 2>&1
echo "Running 'nginx -t' in an nginx:1.27-alpine container..."
docker run --rm -v "$CONF_D:/etc/nginx/conf.d:ro" nginx:1.27-alpine nginx -t
rc=$?
echo
if [ $rc -eq 0 ]; then echo "PASS: nginx accepts the generated configuration."; else echo "FAIL: nginx rejected the configuration."; fi
exit $rc
