#!/usr/bin/env bash
# tests/run.sh — offline test suite for the generator, validation, and
# idempotency. Requires: bash, yq, envsubst. Does NOT require docker.
# Usage: bash tests/run.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
assert_contains()   { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()     { if grep -qF -- "$2" "$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }
assert_count()      { local n; n="$(grep -cF -- "$2" "$1")"; [ "$n" = "$3" ] && ok "$4" || bad "$4 (got $n want $3)"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "SKIP: $1 not installed"; exit 0; }; }
need yq; need envsubst

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/nginx/conf.d" "$WORK/templates"
cp "$ROOT_DIR"/templates/*.tmpl "$WORK/templates/"

# environment for the generator
export TEMPLATES_DIR="$WORK/templates"
export CONF_D="$WORK/nginx/conf.d"
export CONF_TMP="$WORK/nginx/.conf.d.tmp"
export NETWORKS_FILE="$WORK/nginx/.networks"
export NGINX_DIR="$WORK/nginx"
export CERTBOT_LIVE="$WORK/nginx/certbot/conf/live"
export COMPOSE_NET_FILE="$WORK/docker-compose.networks.yml"
export CERT_NAME="sorch"
export SERVICES_FILE="$WORK/services.yml"

# quiet ui
source "$ROOT_DIR/lib/ui.sh"; ui_dim(){ :; }; ui_success(){ :; }; ui_warn(){ :; }; ui_info(){ :; }; ui_error(){ printf 'ERR %s\n' "$*" >&2; }
source "$ROOT_DIR/lib/deps.sh"
source "$ROOT_DIR/lib/yaml.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/generate.sh"

fixture() {
  cat > "$SERVICES_FILE" <<YML
defaults:
  certbot_email: t@example.com
  environment: $1
projects:
  demo:
    enabled: true
    services:
      - name: app
        domains: [app.example.com]
        type: docker
        upstream: app-web:3000
        root: ""
        ssl: $2
        websocket: $3
        deploy: ""
        networks: [appnet]
      - name: api
        domains: [api.example.com]
        type: host
        upstream: 127.0.0.1:9000
        root: ""
        ssl: $2
        websocket: false
        deploy: ""
        networks: []
      - name: site
        domains: [example.com, www.example.com]
        type: static
        upstream: ""
        root: /var/www/site
        ssl: $2
        websocket: false
        deploy: ""
        networks: []
YML
}

echo "== production, ssl=true, websocket=true, cert present =="
fixture production true true
mkdir -p "$CERTBOT_LIVE/$CERT_NAME"; : > "$CERTBOT_LIVE/$CERT_NAME/fullchain.pem"
cmd_generate >/dev/null 2>&1
D="$CONF_D/demo-app.conf"; H="$CONF_D/demo-api.conf"; S="$CONF_D/demo-site.conf"
assert_count "$D" "server {" 2 "docker+ssl -> 2 server blocks (redirect + https)"
assert_contains "$D" "return 301 https://" "docker+ssl -> http redirect"
assert_contains "$D" "listen 443 ssl;" "docker+ssl -> https listener"
assert_contains "$D" "set \$sorch_upstream http://app-web:3000;" "docker -> variable upstream (resilient)"
assert_contains "$D" "resolver 127.0.0.11" "docker -> docker DNS resolver"
assert_contains "$D" 'proxy_set_header Upgrade' "websocket headers present"
assert_contains "$D" "/etc/letsencrypt/live/sorch/fullchain.pem" "https references cert"
assert_contains "$H" "proxy_pass http://host.docker.internal:9000;" "host -> host.docker.internal"
assert_absent  "$H" 'proxy_set_header Upgrade' "no websocket headers when false"
assert_contains "$S" "root /var/www/site;" "static -> root"
assert_contains "$S" "server_name example.com www.example.com;" "static multi-domain server_name"
assert_contains "$COMPOSE_NET_FILE" "appnet:" "compose override lists external net"

echo "== production, ssl=true, cert ABSENT -> http-only fallback =="
fixture production true false
rm -rf "$CERTBOT_LIVE"
cmd_generate >/dev/null 2>&1
assert_count "$CONF_D/demo-app.conf" "server {" 1 "no cert -> single http server block"
assert_absent "$CONF_D/demo-app.conf" "listen 443" "no cert -> no https block"

echo "== production, ssl=false -> plain http =="
fixture production false false
cmd_generate >/dev/null 2>&1
assert_absent  "$CONF_D/demo-app.conf" "return 301" "ssl=false -> no redirect"
assert_contains "$CONF_D/demo-app.conf" "set \$sorch_upstream http://app-web:3000;" "ssl=false still proxies (variable)"

echo "== local -> http only =="
fixture local true true
cmd_generate >/dev/null 2>&1
assert_count "$CONF_D/demo-app.conf" "server {" 1 "local -> single http block"
assert_absent "$CONF_D/demo-app.conf" "listen 443" "local -> no https"

echo "== local --tls -> http + https =="
cmd_generate --tls >/dev/null 2>&1
assert_count "$CONF_D/demo-app.conf" "server {" 2 "local --tls -> http + https"
assert_absent "$CONF_D/demo-app.conf" "return 301" "local --tls -> no forced redirect"

echo "== idempotency =="
fixture production true true
mkdir -p "$CERTBOT_LIVE/$CERT_NAME"; : > "$CERTBOT_LIVE/$CERT_NAME/fullchain.pem"
cmd_generate >/dev/null 2>&1; cp -r "$CONF_D" "$WORK/g1"
cmd_generate >/dev/null 2>&1
if diff -r "$WORK/g1" "$CONF_D" >/dev/null; then ok "generate is idempotent"; else bad "generate not idempotent"; fi

echo "== validation negative cases =="
neg() {
  cat > "$SERVICES_FILE" <<YML
defaults: { environment: production }
projects:
  d:
    enabled: true
    services:
$1
YML
  if config_validate >/dev/null 2>&1; then bad "$2 (should be invalid)"; else ok "$2"; fi
}
neg '      - { name: a, type: docker, domains: [x.com], upstream: bad, root: "", ssl: false, websocket: false, deploy: "", networks: [] }' "bad upstream rejected"
neg '      - { name: a, type: static, domains: [x.com], upstream: "", root: "", ssl: false, websocket: false, deploy: "", networks: [] }' "static without root rejected"
neg '      - { name: a, type: docker, domains: [dup.com], upstream: x:1, root: "", ssl: false, websocket: false, deploy: "", networks: [] }
      - { name: b, type: docker, domains: [dup.com], upstream: y:2, root: "", ssl: false, websocket: false, deploy: "", networks: [] }' "duplicate domain rejected"

echo
echo "-------------------------------------"
printf 'Total: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
