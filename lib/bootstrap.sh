#!/usr/bin/env bash
# lib/bootstrap.sh — install dependencies on a fresh host, no sudo required.
# Works on Linux (apt/dnf/yum), macOS (brew), and Windows Git Bash (winget/scoop
# or direct binary download). yq & mkcert install as user binaries; gum is
# optional (the CLI falls back to plain prompts without it).

_OS()   { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo windows ;; Darwin) echo mac ;; *) echo linux ;; esac; }
_ARCH() { case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo amd64 ;; esac; }
_EXT()  { [ "$(_OS)" = "windows" ] && echo ".exe" || echo ""; }
_can_sudo() { command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; }

# user-writable bin dir that is (or becomes) on PATH.
_bindir() { [ "$(_OS)" = "windows" ] && echo "$HOME/bin" || echo "$HOME/.local/bin"; }

PATH_HINT=""
_ensure_path() {
  local d; d="$(_bindir)"; mkdir -p "$d"
  case ":$PATH:" in *":$d:"*) : ;; *) export PATH="$d:$PATH"; PATH_HINT="$d" ;; esac
}

_dl() {
  local url="$1" out="$2"
  if has_cmd curl; then curl -fsSL "$url" -o "$out"
  elif has_cmd wget; then wget -qO "$out" "$url"
  else ui_error "Need curl or wget to download."; return 1; fi
}

_install_yq() {
  has_cmd yq && { ui_dim "yq present"; return 0; }
  ui_info "Installing yq..."
  local os; os="$(_OS)"
  # try native package managers first (they put it on PATH cleanly)
  if [ "$os" = "windows" ]; then
    has_cmd winget && winget install -e --id MikeFarah.yq --accept-source-agreements --accept-package-agreements >/dev/null 2>&1
    ! has_cmd yq && has_cmd scoop && scoop install yq >/dev/null 2>&1
  fi
  if ! has_cmd yq; then
    _ensure_path
    local dir plat arch ext; dir="$(_bindir)"; arch="$(_ARCH)"; ext="$(_EXT)"
    case "$os" in windows) plat=windows ;; mac) plat=darwin ;; *) plat=linux ;; esac
    _dl "https://github.com/mikefarah/yq/releases/latest/download/yq_${plat}_${arch}${ext}" "$dir/yq${ext}" \
      && chmod +x "$dir/yq${ext}" 2>/dev/null
  fi
  has_cmd yq && ui_success "yq installed ($(yq --version 2>/dev/null))" || ui_error "yq install failed (required)."
}

_install_mkcert() {
  has_cmd mkcert && { ui_dim "mkcert present"; return 0; }
  ui_info "Installing mkcert (only needed for local --tls)..."
  local os; os="$(_OS)"
  if [ "$os" = "windows" ]; then
    has_cmd winget && winget install -e --id FiloSottile.mkcert --accept-source-agreements --accept-package-agreements >/dev/null 2>&1
    ! has_cmd mkcert && has_cmd scoop && scoop install mkcert >/dev/null 2>&1
  elif [ "$os" = "mac" ] && has_cmd brew; then
    brew install mkcert >/dev/null 2>&1
  elif _can_sudo; then
    local pm; pm="$(detect_pkg_manager)"
    case "$pm" in apt) sudo apt-get install -y -q mkcert libnss3-tools 2>/dev/null ;; dnf|yum) sudo "$pm" install -y mkcert nss-tools 2>/dev/null ;; esac
  fi
  if ! has_cmd mkcert; then
    _ensure_path
    local dir plat arch ext; dir="$(_bindir)"; arch="$(_ARCH)"; ext="$(_EXT)"
    case "$os" in windows) plat=windows ;; mac) plat=darwin ;; *) plat=linux ;; esac
    _dl "https://dl.filippo.io/mkcert/latest?for=${plat}/${arch}" "$dir/mkcert${ext}" \
      && chmod +x "$dir/mkcert${ext}" 2>/dev/null
  fi
  has_cmd mkcert && ui_success "mkcert installed" || ui_warn "mkcert not installed (only needed for 'up --tls')."
}

_install_gum() {
  has_cmd gum && { ui_dim "gum present"; return 0; }
  ui_info "Installing gum (optional — nicer menus)..."
  local os; os="$(_OS)"
  case "$os" in
    windows)
      has_cmd winget && winget install -e --id charmbracelet.gum --accept-source-agreements --accept-package-agreements >/dev/null 2>&1
      ! has_cmd gum && has_cmd scoop && scoop install gum >/dev/null 2>&1
      ;;
    mac) has_cmd brew && brew install gum >/dev/null 2>&1 ;;
    linux)
      if _can_sudo; then
        local pm; pm="$(detect_pkg_manager)"
        case "$pm" in
          apt)
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
            sudo apt-get update -y -q && sudo apt-get install -y -q gum ;;
          dnf|yum) sudo "$pm" install -y gum 2>/dev/null ;;
        esac
      fi
      ;;
  esac
  has_cmd gum && ui_success "gum installed" || ui_warn "gum not installed — the CLI uses plain text prompts instead (works fine)."
}

_check_docker() {
  if has_cmd docker && has_docker_compose; then ui_dim "docker + compose present"; return 0; fi
  local os; os="$(_OS)"
  if [ "$os" != "linux" ]; then
    ui_warn "Docker not detected. Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
    return 0
  fi
  if ! has_cmd docker; then
    if _can_sudo && has_cmd curl; then ui_info "Installing Docker..."; curl -fsSL https://get.docker.com | sudo sh
    else ui_warn "Install Docker manually: https://docs.docker.com/engine/install/"; fi
  fi
  if ! has_docker_compose && _can_sudo; then
    local pm; pm="$(detect_pkg_manager)"
    case "$pm" in apt) sudo apt-get install -y -q docker-compose-plugin ;; dnf|yum) sudo "$pm" install -y docker-compose-plugin ;; esac
  fi
}

cmd_bootstrap() {
  local os; os="$(_OS)"
  ui_title "Bootstrapping dependencies (os: $os)"
  _check_docker
  _install_yq
  _install_gum
  _install_mkcert

  echo
  ui_info "Dependency status:"
  local d
  for d in docker "docker compose" yq gum mkcert; do
    case "$d" in
      "docker compose") has_docker_compose && ui_success "docker compose" || ui_warn "docker compose (missing)" ;;
      gum|mkcert) has_cmd "$d" && ui_success "$d" || ui_warn "$d (optional, missing)" ;;
      *) has_cmd "$d" && ui_success "$d" || ui_error "$d (missing)" ;;
    esac
  done

  if [ -n "$PATH_HINT" ]; then
    echo
    ui_warn "Added '$PATH_HINT' to PATH for this session."
    if [ "$os" = "windows" ]; then
      ui_dim "Git Bash auto-adds ~/bin to PATH on new shells, so this persists. Open a new Git Bash if a tool isn't found."
    else
      ui_dim "Add it permanently:  echo 'export PATH=\"$PATH_HINT:\$PATH\"' >> ~/.bashrc"
    fi
  fi
}
