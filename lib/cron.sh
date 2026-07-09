#!/usr/bin/env bash
# lib/cron.sh — install/remove a monthly certificate-renewal cron on the host.
# The certbot container already attempts renewal every 12h; this host cron adds
# a belt-and-suspenders monthly renew + nginx reload, tagged per project so it
# is safe to install/remove idempotently. Paths are derived, never hardcoded.

_cron_marker() { printf 'SORCH_RENEW=%s' "${COMPOSE_PROJECT_NAME:-sorch}"; }

cron_install() {
  command -v crontab >/dev/null 2>&1 || { ui_warn "crontab not found; skipping cron install."; return 0; }
  local script="$ROOT_DIR/shell_scripts/cron-renew-cert.sh"
  local log="$ROOT_DIR/nginx/logs/cron_renew.log"
  local marker; marker="$(_cron_marker)"
  local job="0 3 1 * * $marker \"$script\" >> \"$log\" 2>&1"
  ( crontab -l 2>/dev/null | grep -vF "$marker"; echo "$job" ) | crontab -
  ui_dim "Installed monthly cert-renew cron."
}

cron_remove() {
  command -v crontab >/dev/null 2>&1 || return 0
  local marker; marker="$(_cron_marker)"
  ( crontab -l 2>/dev/null | grep -vF "$marker" ) | crontab - 2>/dev/null || true
  ui_dim "Removed cert-renew cron."
}
