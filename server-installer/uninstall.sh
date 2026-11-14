#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Safe Uninstaller
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
COMMON_DIR="$SCRIPT_DIR/../common"

# shellcheck source=/dev/null
source "$COMMON_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/installer_core.sh"

PURGE_DATA=false
FORCE=false

usage() {
  cat << 'EOF'
CLIProxyAPI Account Manager Uninstaller
Usage:
  sudo ./uninstall.sh [options]

Options:
  --purge-data   Remove OAuth credentials and configuration (DESTRUCTIVE, preserves backups)
  -f, --force    Skip confirmation prompts
  -h, --help     Show this help message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data) PURGE_DATA=true; shift ;;
    -f|--force) FORCE=true; shift ;;
    -h|--help) usage ;;
    *) log_err "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 && "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  log_err "Uninstaller must be run as root (or with sudo)."
  exit 1
fi

if [[ "$FORCE" == "false" && -t 0 ]]; then
  echo "Are you sure you want to uninstall CLIProxyAPI Account Manager? [y/N]"
  read -r reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 0
  fi
fi

log_info "Stopping and disabling systemd service..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop "$DEFAULT_AM_SERVICE" 2>/dev/null || true
  systemctl disable "$DEFAULT_AM_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service"
  systemctl daemon-reload 2>/dev/null || true
fi

log_info "Removing Account Manager application files..."
rm -rf "$DEFAULT_APP_DIR"
rm -f "/usr/local/bin/cliproxy-manager"

if [[ "$PURGE_DATA" == "true" ]]; then
  log_warn "Purging Account Manager configuration and local state as requested..."
  rm -rf "$DEFAULT_CONFIG_DIR"
  rm -rf "$DEFAULT_DATA_DIR"
  rm -rf "$DEFAULT_LOG_DIR"

  # Remove the forwarding policy and tunnel key this product created. The
  # dedicated account itself is left in place so a reinstall can reuse it.
  remove_restricted_authorized_keys "/home/$DEFAULT_TUNNEL_USER/.ssh/authorized_keys" \
    "127.0.0.1" "$DEFAULT_PORT" \
    || log_warn "Could not remove the managed tunnel key."
  remove_tunnel_sshd_policy || log_warn "Could not remove the managed sshd policy."
else
  log_info "Preserving user configuration, logs, backups, OAuth data, and SSH access."
  log_info "  - Configuration: $DEFAULT_CONFIG_DIR"
  log_info "  - OAuth credentials: $DEFAULT_AUTH_DIR"
  log_info "  - Backups: $DEFAULT_BACKUP_ROOT"
  log_info "  - Tunnel user and restricted SSH policy: /home/$DEFAULT_TUNNEL_USER, $SSHD_CONFIG_PATH"
  log_info "  - Use 'sudo ./uninstall.sh --purge-data' to remove the tunnel key and sshd policy."
fi

log_ok "CLIProxyAPI Account Manager uninstalled successfully."
