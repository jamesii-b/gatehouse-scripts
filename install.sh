#!/usr/bin/env bash
# =============================================================================
# Gatehouse Installer
# Supports: Ubuntu 20.04+, Debian 11+, RHEL/CentOS/Amazon Linux 2/2023
# Usage:
#   Interactive:            ./install.sh
#   Non-interactive Docker: INSTALL_MODE=docker    ./install.sh
#   Non-interactive bare:   INSTALL_MODE=baremetal ./install.sh
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────

readonly FRONTEND_REPO="https://github.com/CoryHawkless/gatehouse-ui.git"
readonly BACKEND_REPO="https://github.com/CoryHawkless/gatehouse-api.git"
readonly SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="/opt/gatehouse"
readonly LOG_FILE="/tmp/gatehouse-install-$(date +%Y%m%d-%H%M%S).log"
readonly MIN_DISK_MB=2048
readonly MIN_RAM_MB=512
PKG="npm"  # set to 'bun' in install_frontend if available

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC}    $1" | tee -a "$LOG_FILE"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2 | tee -a "$LOG_FILE"; exit 1; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYAN}[..]${NC}    $1" | tee -a "$LOG_FILE"; }
step()  { echo -e "\n${BOLD}${CYAN}▶ $1${NC}" | tee -a "$LOG_FILE"; }
need()  { command -v "$1" &>/dev/null || err "'$1' is required but not installed."; }

# Run as root when uid=0, otherwise via sudo.
maybe_sudo() { [ "$(id -u)" -eq 0 ] && "$@" || sudo "$@"; }

# ── Cleanup trap ──────────────────────────────────────────────────────────────

_on_exit() {
    local code=$?
    if [ $code -ne 0 ]; then
        echo -e "\n${RED}[ERROR]${NC} Installation failed (exit $code)." >&2
        echo -e "  Log: $LOG_FILE" >&2
    fi
}
trap _on_exit EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
    else
        err "Cannot detect OS. /etc/os-release not found."
    fi

    case "$OS_ID" in
        ubuntu|debian|linuxmint)  PKG_MANAGER="apt"  ;;
        rhel|centos|fedora|amzn|rocky|almalinux) PKG_MANAGER="dnf" ;;
        *) err "Unsupported OS: $OS_ID. Supported: Ubuntu, Debian, RHEL/CentOS/Amazon Linux." ;;
    esac

    ok "OS: $OS_ID $OS_VERSION (package manager: $PKG_MANAGER)"
}

check_system_resources() {
    local disk_free ram_mb
    disk_free=$(df -m /tmp 2>/dev/null | awk 'NR==2{print $4}' || echo 9999)
    ram_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 9999)

    [ "$disk_free" -lt "$MIN_DISK_MB" ] && \
        err "Insufficient disk space: ${disk_free}MB free, ${MIN_DISK_MB}MB required."
    [ "$ram_mb" -lt "$MIN_RAM_MB" ] && \
        warn "Low RAM: ${ram_mb}MB available. Recommended: ${MIN_RAM_MB}MB+."

    ok "Resources: ${disk_free}MB disk free, ${ram_mb}MB RAM"
}

preflight() {
    step "Pre-flight checks"
    check_os
    check_system_resources
    [ "$(uname -s)" = "Linux" ] || err "This installer only supports Linux."
}

# ── Shared helpers ─────────────────────────────────────────────────────────────

clone_repos() {
    step "Cloning repositories"
    maybe_sudo mkdir -p "$INSTALL_DIR"
    maybe_sudo chown "$(id -u):$(id -g)" "$INSTALL_DIR"
    rm -rf "${INSTALL_DIR}/gatehouse-ui" "${INSTALL_DIR}/gatehouse-api"

    git clone --depth=1 --branch main "$FRONTEND_REPO" "$INSTALL_DIR/gatehouse-ui" \
        >> "$LOG_FILE" 2>&1
    ok "Cloned gatehouse-ui → $INSTALL_DIR/gatehouse-ui"

    git clone --depth=1 --branch main "$BACKEND_REPO"  "$INSTALL_DIR/gatehouse-api" \
        >> "$LOG_FILE" 2>&1
    ok "Cloned gatehouse-api → $INSTALL_DIR/gatehouse-api"
}

wait_healthy() {
    local svc=$1 n=0 max=120
    echo -n "    Waiting for $svc"
    while [ $n -lt $max ]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "missing")
        case "$status" in
            healthy)   echo " ✓"; return 0 ;;
            unhealthy) echo ""
                       docker logs --tail 30 "$svc" 2>&1 | tee -a "$LOG_FILE"
                       err "$svc reported unhealthy" ;;
        esac
        sleep 1; n=$((n+1))
        [ $((n % 10)) -eq 0 ] && echo -n " ${n}s" || echo -n "."
    done
    echo ""
    err "$svc did not become healthy within ${max}s"
}

# ── Docker path ───────────────────────────────────────────────────────────────

check_env() {
    step "Validating .env"
    if [[ ! -f "$SCRIPTS_DIR/.env" ]]; then
        if [[ -f "$SCRIPTS_DIR/.env.example" ]]; then
            cp "$SCRIPTS_DIR/.env.example" "$SCRIPTS_DIR/.env"
            err ".env not found. Copied .env.example → .env. Fill in all values, then re-run."
        else
            err "No .env in $SCRIPTS_DIR. Create one — see .env.example."
        fi
    fi
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/.env"

    local missing=()
    [[ -z "${SECRET_KEY:-}"   ]] && missing+=("SECRET_KEY")
    [[ -z "${DATABASE_URL:-}" ]] && missing+=("DATABASE_URL")

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required .env variables: ${missing[*]}"
    fi
    ok ".env validated ($(wc -l < "$SCRIPTS_DIR/.env") vars loaded)"
}

docker_install() {
    step "Docker installation"
    need docker

    docker compose version &>/dev/null || \
        err "Docker Compose v2 not found. Install: https://docs.docker.com/compose/install/"

    docker info &>/dev/null || \
        err "Docker daemon is not running. Start it: sudo systemctl start docker"

    check_env

    info "Building images (source cloned from GitHub inside Docker)..."
    cd "$SCRIPTS_DIR"
    docker compose build --no-cache >> "$LOG_FILE" 2>&1
    docker compose up -d           >> "$LOG_FILE" 2>&1

    step "Waiting for all services to be healthy"
    for svc in gatehouse-redis gatehouse-backend gatehouse-frontend; do
        wait_healthy "$svc"
    done

    ok "Docker installation complete."
    _print_docker_summary
}

_print_docker_summary() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         Gatehouse is running             ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Frontend  :  http://localhost:3000      ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Backend   :  internal (port 5000)       ${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Logs   :  docker compose logs -f        ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Stop   :  docker compose down           ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Restart:  docker compose up -d          ${BOLD}║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Install log: ${LOG_FILE}"
}

# ── Bare-metal path ───────────────────────────────────────────────────────────

_apt_install() {
    DEBIAN_FRONTEND=noninteractive maybe_sudo apt-get install -y -qq "$@" \
        >> "$LOG_FILE" 2>&1
}

_dnf_install() {
    maybe_sudo dnf install -y -q "$@" >> "$LOG_FILE" 2>&1
}

install_system_deps() {
    step "Installing system dependencies"
    case "$PKG_MANAGER" in
        apt)
            maybe_sudo apt-get update -qq >> "$LOG_FILE" 2>&1
            _apt_install git curl ca-certificates python3 python3-venv python3-pip
            ;;
        dnf)
            maybe_sudo dnf check-update -q >> "$LOG_FILE" 2>&1 || true
            _dnf_install git curl ca-certificates python3 python3-pip
            # python3-venv is part of python3 stdlib on RHEL
            ;;
    esac
    ok "System dependencies installed"
}

install_node() {
    if command -v node &>/dev/null; then
        ok "Node.js: $(node -v)"; return
    fi
    info "Installing Node.js 18..."
    case "$PKG_MANAGER" in
        apt)
            curl -fsSL https://deb.nodesource.com/setup_18.x 2>>"$LOG_FILE" \
                | maybe_sudo bash - >> "$LOG_FILE" 2>&1
            _apt_install nodejs
            ;;
        dnf)
            curl -fsSL https://rpm.nodesource.com/setup_18.x 2>>"$LOG_FILE" \
                | maybe_sudo bash - >> "$LOG_FILE" 2>&1
            _dnf_install nodejs
            ;;
    esac
    ok "Node.js: $(node -v)"
}

install_frontend() {
    step "Building gatehouse-ui"
    install_node

    command -v bun &>/dev/null && PKG="bun"
    ok "Package manager: $PKG"

    cd "$INSTALL_DIR/gatehouse-ui"
    $PKG install --no-audit --prefer-offline >> "$LOG_FILE" 2>&1
    $PKG run build                           >> "$LOG_FILE" 2>&1
    ok "Frontend built → $INSTALL_DIR/gatehouse-ui/dist"
}

install_backend() {
    step "Installing gatehouse-api"
    cd "$INSTALL_DIR/gatehouse-api"

    ok "Python: $(python3 --version)"
    python3 -m venv venv >> "$LOG_FILE" 2>&1
    # shellcheck disable=SC1091
    source venv/bin/activate
    pip install --upgrade pip -q          >> "$LOG_FILE" 2>&1
    pip install -r requirements.txt -q   >> "$LOG_FILE" 2>&1
    pip install gunicorn -q              >> "$LOG_FILE" 2>&1
    ok "Backend dependencies installed (venv: $INSTALL_DIR/gatehouse-api/venv)"
}

install_cli() {
    [[ ! -t 0 ]] && return  # skip in non-interactive / piped mode

    read -rp $'\nInstall gatehouse CLI to /usr/local/bin? (y/n): ' do_cli
    [[ "$do_cli" != "y" ]] && return

    local src="$INSTALL_DIR/gatehouse-api/client/gatehouse-cli.py"
    if [[ -f "$src" ]]; then
        maybe_sudo cp "$src" /usr/local/bin/gatehouse-cli
        maybe_sudo chmod +x /usr/local/bin/gatehouse-cli
        ok "CLI installed → /usr/local/bin/gatehouse-cli"
    else
        warn "CLI binary not found at $src — skipping."
    fi
}

bare_install() {
    install_system_deps
    clone_repos
    install_frontend
    install_backend
    install_cli

    ok "Bare-metal installation complete."
    _print_baremetal_summary
}

_print_baremetal_summary() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║              Gatehouse installed (bare-metal)                ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Set env vars before starting:                               ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    export SECRET_KEY=<random-64-char-string>                 ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    export DATABASE_URL=postgresql://user:pass@host/dbname    ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    export REDIS_URL=redis://localhost:6379/0                 ${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Start API:                                                  ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    cd $INSTALL_DIR/gatehouse-api                           ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    source venv/bin/activate                                  ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    gunicorn --bind 0.0.0.0:5000 --workers 4 wsgi:app         ${BOLD}║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  Serve frontend (static files):                              ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}    npx serve -s $INSTALL_DIR/gatehouse-ui/dist -l 3000     ${BOLD}║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Install log: ${LOG_FILE}"
}

# ── Entry point ────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BOLD}${CYAN}Gatehouse Installer${NC}"
    echo -e "${CYAN}════════════════════════════════════${NC}"
    echo -e "  Log file: ${LOG_FILE}"
    echo ""

    preflight

    local mode="${INSTALL_MODE:-}"
    if [[ -z "$mode" ]]; then
        read -rp "Install using Docker? (y/n): " ans
        [[ "$ans" == "y" ]] && mode="docker" || mode="baremetal"
    fi

    case "$mode" in
        docker)    docker_install ;;
        baremetal) bare_install   ;;
        *) err "Unknown INSTALL_MODE '$mode'. Use 'docker' or 'baremetal'." ;;
    esac
}

main "$@"
