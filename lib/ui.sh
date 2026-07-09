#!/usr/bin/env bash
# lib/ui.sh — interactive UI helpers.
# Every prompt uses `gum` when available and falls back to plain read/select so
# the CLI still works under Git Bash / MinTTY where gum's TTY handling breaks.
# No `tput` is used (also unreliable under MinTTY).

# --- colors (ANSI, degrade gracefully) --------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

_has_gum() { command -v gum >/dev/null 2>&1; }

# --- messaging --------------------------------------------------------------
ui_info()    { printf '%s\n' "${C_CYAN}➜${C_RESET} $*"; }
ui_success() { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
ui_warn()    { printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
ui_error()   { printf '%s\n' "${C_RED}✗ $*${C_RESET}" >&2; }
ui_title()   { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }
ui_dim()     { printf '%s\n' "${C_DIM}$*${C_RESET}"; }

# ui_input <prompt> [default] [--placeholder text]
# echoes the entered value.
ui_input() {
  local prompt="$1" default="${2:-}" placeholder=""
  shift 2 2>/dev/null || shift $#
  while [ $# -gt 0 ]; do
    case "$1" in
      --placeholder) placeholder="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if _has_gum; then
    gum input --prompt "$prompt " --value "$default" \
      ${placeholder:+--placeholder "$placeholder"}
  else
    local reply
    if [ -n "$default" ]; then
      read -r -p "$prompt [$default]: " reply
      printf '%s' "${reply:-$default}"
    else
      read -r -p "$prompt: " reply
      printf '%s' "$reply"
    fi
  fi
}

# ui_confirm <prompt>  -> returns 0 for yes, 1 for no. Default no.
ui_confirm() {
  local prompt="$1"
  if _has_gum; then
    gum confirm "$prompt"
    return $?
  fi
  local reply
  read -r -p "$prompt (y/N): " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ui_choose <prompt> <option...>  -> echoes the chosen option.
ui_choose() {
  local prompt="$1"; shift
  if [ $# -eq 0 ]; then return 1; fi
  if _has_gum; then
    printf '%s\n' "$@" | gum choose --header "$prompt"
    return $?
  fi
  printf '%s\n' "$prompt" >&2
  local opt i=1
  for opt in "$@"; do printf '  %d) %s\n' "$i" "$opt" >&2; i=$((i+1)); done
  local reply
  while true; do
    read -r -p "Select [1-$#]: " reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le $# ]; then
      eval "printf '%s' \"\${$reply}\""
      return 0
    fi
    printf 'Invalid selection.\n' >&2
  done
}

# ui_multichoose <prompt> <option...> -> echoes chosen options (newline sep).
# Plain fallback: comma/space separated indexes.
ui_multichoose() {
  local prompt="$1"; shift
  if [ $# -eq 0 ]; then return 0; fi
  if _has_gum; then
    printf '%s\n' "$@" | gum choose --no-limit --header "$prompt"
    return $?
  fi
  printf '%s (space/comma separated numbers, empty for none)\n' "$prompt" >&2
  local opt i=1
  for opt in "$@"; do printf '  %d) %s\n' "$i" "$opt" >&2; i=$((i+1)); done
  local reply idx
  read -r -p "Select: " reply
  reply="${reply//,/ }"
  for idx in $reply; do
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le $# ]; then
      eval "printf '%s\n' \"\${$idx}\""
    fi
  done
}
