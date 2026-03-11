#!/bin/bash
# ============================================================
# Installer.sh - auditd-based command logging system
# https://github.com/jaekwon-park/bash_history_extend/
# ============================================================
# Installs audit-cmd-logger: a Go-based audisp plugin that logs
# every command executed by logged-in users via auditd.
#
# Requires: auditd 3.0+
#
# Supports:
#   RHEL / CentOS / Rocky / AlmaLinux 8/9
#   Debian / Ubuntu 20.04+
#   Any systemd-based Linux distribution with auditd 3.x
# ============================================================

set -euo pipefail

# ── configuration ─────────────────────────────────────────────
BINARY_NAME="audit-cmd-logger"
BINARY_INSTALL_PATH="/usr/local/bin/${BINARY_NAME}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cmd/${BINARY_NAME}"
RULES_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rules/audit-cmd-logging.rules"
PLUGIN_CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugins/audit-cmd-logger.conf"
LOGROTATE_CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logrotate/cmd_history"

GITHUB_REPO="jaekwon-park/bash_history_extend"
LOG_FILE="/var/log/cmd_history.log"
CHANGED_FILE_DIR="/var/log/changed_file"
GO_MIN_VERSION="1.21"
GO_DOWNLOAD_VERSION="1.21.13"

# ── colours ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── root check ────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root."
fi

# ─────────────────────────────────────────────────────────────
# Utility functions
# ─────────────────────────────────────────────────────────────

detect_pkg_manager() {
    if command -v dnf &>/dev/null;  then echo "dnf"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v apt-get &>/dev/null; then echo "apt"
    else die "Unsupported package manager. Please install auditd manually."
    fi
}

install_package() {
    local pkg="$1"
    local mgr
    mgr="$(detect_pkg_manager)"
    info "Installing ${pkg} via ${mgr}..."
    case "${mgr}" in
        dnf|yum) ${mgr} install -y "${pkg}" ;;
        apt)     apt-get install -y "${pkg}" ;;
    esac
}

check_auditd_version() {
    local ver major

    # Method 1: rpm (RHEL / CentOS / Rocky / AlmaLinux)
    if command -v rpm &>/dev/null; then
        ver="$(rpm -q --queryformat '%{VERSION}' audit 2>/dev/null | grep -oP '^\d+\.\d+')"
    fi

    # Method 2: dpkg (Debian / Ubuntu)
    if [[ -z "${ver}" ]] && command -v dpkg &>/dev/null; then
        ver="$(dpkg -l auditd 2>/dev/null | awk '/^ii/{print $3}' | grep -oP '^\d+\.\d+')"
    fi

    # Method 3: /etc/audit/plugins.d 존재 여부로 3.x 판별
    if [[ -z "${ver}" ]]; then
        if [[ -d /etc/audit/plugins.d ]]; then
            info "auditd version: unknown (plugins.d directory found, assuming 3.x)"
            return 0
        fi
        die "auditd 3.0+ is required but version could not be determined. Aborting."
    fi

    major="${ver%%.*}"
    if [[ "${major}" -lt 3 ]]; then
        die "auditd 3.0+ is required. Detected version: ${ver}. Aborting."
    fi

    info "auditd version: ${ver}"
}

# auditd 3.x: plugin directory is always /etc/audit/plugins.d
audisp_plugin_dir() {
    echo "/etc/audit/plugins.d"
}

# auditd 3.x: rules directory is always /etc/audit/rules.d
audit_rules_dir() {
    echo "/etc/audit/rules.d"
}

# ─────────────────────────────────────────────────────────────
# Go toolchain detection / installation
# ─────────────────────────────────────────────────────────────

go_version_ok() {
    local go_bin="$1"
    local ver
    ver="$("${go_bin}" version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)"
    if [[ -z "${ver}" ]]; then return 1; fi
    local maj="${ver%%.*}"
    local min="${ver##*.}"
    local need_maj="${GO_MIN_VERSION%%.*}"
    local need_min="${GO_MIN_VERSION##*.}"
    if [[ "${maj}" -gt "${need_maj}" ]]; then return 0; fi
    if [[ "${maj}" -eq "${need_maj}" && "${min}" -ge "${need_min}" ]]; then return 0; fi
    return 1
}

find_go() {
    for candidate in go /usr/local/go/bin/go /snap/bin/go; do
        if command -v "${candidate}" &>/dev/null && go_version_ok "${candidate}"; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

install_go_temp() {
    info "Go >= ${GO_MIN_VERSION} not found. Downloading Go ${GO_DOWNLOAD_VERSION}..."
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv6l" ;;
        *)       die "Unsupported architecture: ${arch}" ;;
    esac

    local tarball="go${GO_DOWNLOAD_VERSION}.linux-${arch}.tar.gz"
    local url="https://go.dev/dl/${tarball}"
    local tmpdir
    tmpdir="$(mktemp -d)"

    curl -fsSL -o "${tmpdir}/${tarball}" "${url}" \
        || die "Failed to download Go from ${url}"

    tar -C "${tmpdir}" -xzf "${tmpdir}/${tarball}" \
        || die "Failed to extract Go tarball"

    echo "${tmpdir}/go/bin/go"
}

# ─────────────────────────────────────────────────────────────
# Build binary
# ─────────────────────────────────────────────────────────────

build_binary() {
    local go_bin="$1"
    info "Building ${BINARY_NAME} (static binary)..."
    (
        cd "${SOURCE_DIR}"
        CGO_ENABLED=0 GOOS=linux \
            "${go_bin}" build \
            -ldflags="-extldflags=-static -s -w" \
            -o "${BINARY_INSTALL_PATH}" .
    ) || die "Build failed"
    chmod 755 "${BINARY_INSTALL_PATH}"
    info "Binary installed to ${BINARY_INSTALL_PATH}"
}

# ─────────────────────────────────────────────────────────────
# Download binary from GitHub latest release
# ─────────────────────────────────────────────────────────────

download_from_github() {
    local os arch asset_name download_url api_url

    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) warn "GitHub download: unsupported architecture '${arch}'"; return 1 ;;
    esac

    asset_name="${BINARY_NAME}-${os}-${arch}"
    api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

    info "Fetching latest release info from GitHub..."
    download_url="$(curl -fsSL "${api_url}" 2>/dev/null \
        | grep '"browser_download_url"' \
        | grep "/${asset_name}\"" \
        | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')"

    if [[ -z "${download_url}" ]]; then
        warn "GitHub: release asset '${asset_name}' not found."
        return 1
    fi

    info "Downloading ${asset_name} from GitHub..."
    if curl -fsSL -o "${BINARY_INSTALL_PATH}" "${download_url}"; then
        chmod 755 "${BINARY_INSTALL_PATH}"
        info "Binary installed from GitHub: ${BINARY_INSTALL_PATH}"
        return 0
    else
        warn "GitHub download failed: ${download_url}"
        rm -f "${BINARY_INSTALL_PATH}"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────
# Install binary: local → GitHub → build from source
# ─────────────────────────────────────────────────────────────

install_binary() {
    local prebuilt
    prebuilt="$(dirname "${BASH_SOURCE[0]}")/bin/${BINARY_NAME}"

    # 1. Local prebuilt binary
    if [[ -f "${prebuilt}" ]]; then
        info "Using local pre-compiled binary: ${prebuilt}"
        install -m 755 "${prebuilt}" "${BINARY_INSTALL_PATH}"
        return 0
    fi
    info "Local binary not found (${prebuilt})."

    # 2. GitHub latest release
    if download_from_github; then
        return 0
    fi
    warn "GitHub download failed. Falling back to local source build..."

    # 3. Build from source
    local go_bin tmp_go_dir=""
    if go_bin="$(find_go)"; then
        info "Using Go at: ${go_bin}"
    else
        go_bin="$(install_go_temp)"
        tmp_go_dir="$(dirname "$(dirname "${go_bin}")")"
    fi

    build_binary "${go_bin}"

    if [[ -n "${tmp_go_dir}" ]]; then
        rm -rf "${tmp_go_dir}"
    fi
}

# ─────────────────────────────────────────────────────────────
# Install function
# ─────────────────────────────────────────────────────────────

register() {
    # ── 0. Check SELinux ───────────────────────────────────
    if command -v getenforce &>/dev/null; then
        local selinux_status
        selinux_status="$(getenforce 2>/dev/null)"
        if [[ "${selinux_status}" != "Disabled" ]]; then
            error "======================================================"
            error " SELinux is ${selinux_status}."
            error ""
            error " audit-cmd-logger 바이너리가 auditd 플러그인으로"
            error " 실행될 때 SELinux 정책에 의해 차단될 수 있습니다."
            error ""
            error " 설치 전 아래 중 하나를 선택하세요:"
            error ""
            error "   1) SELinux 비활성화 (권장하지 않음)"
            error "      setenforce 0  # 임시 (재부팅 시 원복)"
            error "      또는 /etc/selinux/config 에서 SELINUX=disabled 설정"
            error ""
            error "   2) 바이너리에 SELinux 컨텍스트 수동 적용 후 재시도"
            error "      chcon -t bin_t /usr/local/bin/audit-cmd-logger"
            error ""
            error " 설치를 중단합니다."
            error "======================================================"
            exit 1
        fi
    fi

    # ── 1. Check / install auditd ──────────────────────────
    if ! command -v auditd &>/dev/null; then
        info "auditd not found. Installing..."
        local mgr
        mgr="$(detect_pkg_manager)"
        case "${mgr}" in
            dnf|yum) install_package "audit" ;;
            apt)     install_package "auditd" ;;
        esac
    fi

    # Require auditd 3.0+
    check_auditd_version

    # ── 2. Install binary (local → GitHub → source build) ──
    install_binary

    # ── 3. Install audit rules ─────────────────────────────
    local rules_dir
    rules_dir="$(audit_rules_dir)"
    info "Installing audit rules to ${rules_dir}/audit-cmd-logging.rules"
    install -m 640 "${RULES_FILE}" "${rules_dir}/audit-cmd-logging.rules"

    # ── 4. Install audisp plugin config ───────────────────
    local plugin_dir
    plugin_dir="$(audisp_plugin_dir)"
    mkdir -p "${plugin_dir}"
    info "Installing audisp plugin config to ${plugin_dir}/audit-cmd-logger.conf"
    install -m 640 "${PLUGIN_CONF}" "${plugin_dir}/audit-cmd-logger.conf"

    # Update path in plugin config to actual binary path
    sed -i "s|^path = .*|path = ${BINARY_INSTALL_PATH}|" \
        "${plugin_dir}/audit-cmd-logger.conf"

    # ── 5. Create log directories ─────────────────────────
    install -m 750 -d "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    touch "${LOG_FILE}"
    chmod 640 "${LOG_FILE}"

    install -m 773 -d "${CHANGED_FILE_DIR}"

    # ── 6. Install logrotate config ───────────────────────
    if [[ -d /etc/logrotate.d ]]; then
        info "Installing logrotate config to /etc/logrotate.d/cmd_history"
        install -m 644 "${LOGROTATE_CONF}" /etc/logrotate.d/cmd_history
    fi

    # ── 7. Load rules and restart auditd ──────────────────
    info "Loading audit rules..."
    if command -v augenrules &>/dev/null; then
        augenrules --load
    else
        auditctl -R "${rules_dir}/audit-cmd-logging.rules" 2>/dev/null || \
            warn "Could not load rules via auditctl. Restart auditd to apply."
    fi

    info "Restarting auditd..."
    if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
        systemctl kill auditd
        systemctl start auditd
    elif command -v service &>/dev/null; then
        systemctl kill auditd
        systemctl start auditd
    else
        warn "Could not restart auditd automatically. Please restart it manually."
    fi

    # ── 8. Enable auditd on boot ──────────────────────────
    if command -v systemctl &>/dev/null; then
        systemctl enable auditd 2>/dev/null || true
    fi

    echo ""
    info "======================================================"
    info " Installation complete!"
    info "======================================================"
    info " Logs:        ${LOG_FILE}"
    info " File diffs:  ${CHANGED_FILE_DIR}/"
    info " Rules:       ${rules_dir}/audit-cmd-logging.rules"
    info " Plugin:      ${plugin_dir}/audit-cmd-logger.conf"
    info ""
    info " Verify with: auditctl -l"
    info " Tail logs:   tail -f ${LOG_FILE}"
    info "======================================================"
}

# ─────────────────────────────────────────────────────────────
# Delete function
# ─────────────────────────────────────────────────────────────

delete() {
    info "Removing audit-cmd-logger..."

    # Remove binary
    rm -f "${BINARY_INSTALL_PATH}"
    info "Removed ${BINARY_INSTALL_PATH}"

    # Remove plugin config
    rm -f "/etc/audit/plugins.d/audit-cmd-logger.conf"
    info "Removed audisp plugin config"

    # Remove audit rules
    local rules_dir
    rules_dir="$(audit_rules_dir)"
    rm -f "${rules_dir}/audit-cmd-logging.rules"
    info "Removed audit rules"

    # Remove logrotate config
    rm -f /etc/logrotate.d/cmd_history

    # Reload rules (remove the cmd_logging rules from active set)
    if command -v augenrules &>/dev/null; then
        augenrules --load 2>/dev/null || true
    fi

    # Restart auditd
    if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null; then
        systemctl restart auditd 2>/dev/null || true
    elif command -v service &>/dev/null; then
        service auditd restart 2>/dev/null || true
    fi

    info "audit-cmd-logger removed successfully."
    warn "Log files retained: ${LOG_FILE} and ${CHANGED_FILE_DIR}/"
    warn "Remove manually if no longer needed."
}

# ─────────────────────────────────────────────────────────────
# Status function
# ─────────────────────────────────────────────────────────────

status() {
    echo ""
    echo "=== audit-cmd-logger status ==="
    echo ""

    echo -n "Binary:        "
    if [[ -f "${BINARY_INSTALL_PATH}" ]]; then
        echo -e "${GREEN}installed${NC} (${BINARY_INSTALL_PATH})"
    else
        echo -e "${RED}NOT installed${NC}"
    fi

    echo -n "auditd:        "
    if command -v auditctl &>/dev/null; then
        local state
        state="$(auditctl -s 2>/dev/null | grep 'enabled' | awk '{print $2}')"
        echo -e "${GREEN}running${NC} (enabled=${state:-?})"
    else
        echo -e "${RED}not found${NC}"
    fi

    echo -n "Rules loaded:  "
    if auditctl -l 2>/dev/null | grep -q cmd_logging; then
        echo -e "${GREEN}yes${NC}"
    else
        echo -e "${RED}no${NC}"
    fi

    echo -n "Log file:      "
    if [[ -f "${LOG_FILE}" ]]; then
        local sz
        sz="$(du -sh "${LOG_FILE}" 2>/dev/null | cut -f1)"
        echo -e "${GREEN}${LOG_FILE}${NC} (${sz})"
    else
        echo -e "${RED}NOT found${NC}"
    fi

    echo ""
    echo "Recent log entries:"
    tail -5 "${LOG_FILE}" 2>/dev/null || echo "  (no entries)"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $(basename "$0") [-i|-d|-s]"
    echo ""
    echo "  -i   Install audit-cmd-logger"
    echo "  -d   Remove audit-cmd-logger"
    echo "  -s   Show installation status"
    echo ""
    exit "${1:-0}"
}

# ─────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────

if [[ $# -ne 1 ]]; then
    usage 1
fi

case "$1" in
    -i) register ;;
    -d) delete ;;
    -s) status ;;
    *)  usage 1 ;;
esac
