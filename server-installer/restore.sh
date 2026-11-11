#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Safe Restore Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
COMMON_DIR="$SCRIPT_DIR/../common"

# shellcheck source=/dev/null
source "$COMMON_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/installer_core.sh"

if [[ "$(id -u)" -ne 0 && "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  log_err "Restore script must be run as root (or with sudo)."
  exit 1
fi

SPECIFIED_BACKUP="${1:-}"
BACKUP_PARENT="${BACKUP_DIR:-$DEFAULT_BACKUP_ROOT}"

if [[ -z "$SPECIFIED_BACKUP" ]]; then
  POINTER_FILE="$BACKUP_PARENT/latest_backup_path"
  if [[ -f "$POINTER_FILE" ]]; then
    SPECIFIED_BACKUP=$(cat "$POINTER_FILE" | tr -d '\r\n')
  else
    log_err "No backup directory specified and latest backup pointer not found."
    exit 1
  fi
fi

if [[ ! -d "$SPECIFIED_BACKUP" ]]; then
  log_err "Specified backup directory does not exist: $SPECIFIED_BACKUP"
  exit 1
fi

log_info "Initiating restore from: $SPECIFIED_BACKUP"

# 1. Verify Backup Integrity Checksums
if [[ -f "$SPECIFIED_BACKUP/SHA256SUMS.txt" ]]; then
  log_info "Validating checksums of backup files..."
  (cd "$SPECIFIED_BACKUP" && sha256sum -c --quiet SHA256SUMS.txt) || {
    log_err "Integrity verification failed! Checksum mismatch detected in backup files."
    exit 1
  }
  log_ok "Backup integrity verified."
fi

# 2. Pre-restore safety snapshot of current configuration
PRE_RESTORE_DIR="$BACKUP_PARENT/pre_restore_safety_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$PRE_RESTORE_DIR"
chmod 0700 "$PRE_RESTORE_DIR"

if [[ -d "$DEFAULT_CONFIG_DIR" ]]; then
  cp -a "$DEFAULT_CONFIG_DIR" "$PRE_RESTORE_DIR/"
fi
log_ok "Current configuration saved to safety recovery point: $PRE_RESTORE_DIR"

# 3. Stage & Restore Configuration
if [[ -d "$SPECIFIED_BACKUP/config" ]]; then
  log_info "Restoring Account Manager configuration..."
  mkdir -p "$DEFAULT_CONFIG_DIR"
  cp -a "$SPECIFIED_BACKUP/config"/. "$DEFAULT_CONFIG_DIR/"
  if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
    chown -R root:cliproxyapi "$DEFAULT_CONFIG_DIR"
  fi
  chmod 0750 "$DEFAULT_CONFIG_DIR"
  chmod 0640 "$DEFAULT_CONFIG_DIR"/* 2>/dev/null || true
fi

# 4. Restore CLIProxyAPI Config and OAuth Data (if present)
if [[ -f "$SPECIFIED_BACKUP/cliproxyapi/config.yaml" ]]; then
  log_info "Restoring CLIProxyAPI configuration..."
  mkdir -p "$(dirname "$DEFAULT_CLIPROXY_CONFIG")"
  cp -a "$SPECIFIED_BACKUP/cliproxyapi/config.yaml" "$DEFAULT_CLIPROXY_CONFIG"
  chmod 0600 "$DEFAULT_CLIPROXY_CONFIG"
fi

if [[ -d "$SPECIFIED_BACKUP/auths" ]]; then
  log_info "Restoring OAuth credentials..."
  mkdir -p "$DEFAULT_AUTH_DIR"
  cp -a "$SPECIFIED_BACKUP/auths"/* "$DEFAULT_AUTH_DIR/" 2>/dev/null || true
  if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
    chown -R cliproxyapi:cliproxyapi "$DEFAULT_AUTH_DIR" 2>/dev/null || true
  fi
  chmod 0700 "$DEFAULT_AUTH_DIR"
  chmod 0600 "$DEFAULT_AUTH_DIR"/* 2>/dev/null || true
fi

# 5. Service Reload
if command -v systemctl >/dev/null 2>&1; then
  log_info "Reloading and restarting services..."
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart "$DEFAULT_AM_SERVICE" 2>/dev/null || true
fi

log_ok "Restore completed successfully from $SPECIFIED_BACKUP"
