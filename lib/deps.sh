#!/usr/bin/env bash
# lib/deps.sh — dependency detection shared by `doctor` and `bootstrap`.

# has_cmd <name>
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# has_docker_compose — true if `docker compose` (v2) works.
has_docker_compose() { docker compose version >/dev/null 2>&1; }

# detect_pkg_manager — echoes apt|dnf|yum|brew|unknown
detect_pkg_manager() {
  if has_cmd apt-get; then echo apt
  elif has_cmd dnf; then echo dnf
  elif has_cmd yum; then echo yum
  elif has_cmd brew; then echo brew
  else echo unknown
  fi
}

# compose — run docker compose with the main file plus the generated network
# override (when present) and a stable project name.
compose() {
  local args=(-p "${COMPOSE_PROJECT_NAME:-sorch}" -f "$COMPOSE_FILE_MAIN")
  [ -f "${COMPOSE_NET_FILE:-}" ] && args+=(-f "$COMPOSE_NET_FILE")
  docker compose "${args[@]}" "$@"
}

# deps_missing — prints the names of required tools that are absent (one/line).
# Args: any of: docker compose yq gum mkcert  (defaults to core set)
deps_missing() {
  local wanted=("$@")
  [ ${#wanted[@]} -eq 0 ] && wanted=(docker compose yq)
  local d
  for d in "${wanted[@]}"; do
    case "$d" in
      compose) has_docker_compose || echo compose ;;
      *)       has_cmd "$d"       || echo "$d" ;;
    esac
  done
}
