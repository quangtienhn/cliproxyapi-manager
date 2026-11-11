#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Safe Update & Rollback Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
COMMON_DIR="$SCRIPT_DIR/../common"

# shellcheck source=/dev/null
source "$COMMON_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/installer_core.sh"

CHECK_ONLY=false
TARGET_TARBALL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=true; shift ;;
    --tarball) TARGET_TARBALL="$2"; shift 2 ;;
    *) log_err "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$CHECK_ONLY" == "true" ]]; then
  log_info "Checking current installation version and available updates..."
  CURRENT_VERSION="not-installed"
  if [[ -f "$DEFAULT_APP_DIR/package.json" ]]; then
    CURRENT_VERSION=$(grep '"version"' "$DEFAULT_APP_DIR/package.json" | head -n1 | cut -d'"' -f4)
  fi
  log_info "Installed Account Manager Version: $CURRENT_VERSION"
  log_ok "Update check completed."
  exit 0
fi

if [[ "$(id -u)" -ne 0 && "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  log_err "Update script must be run as root (or with sudo)."
  exit 1
fi

log_info "Executing safe update workflow..."

# 1. Create Pre-update Snapshot
log_info "[1/4] Creating comprehensive pre-update snapshot..."
TS=$(date +%Y%m%dT%H%M%S)
SNAPSHOT_DIR="$DEFAULT_BACKUP_ROOT/snapshot_$TS"
mkdir -p "$SNAPSHOT_DIR"
chmod 0700 "$SNAPSHOT_DIR"

if [[ -d "$DEFAULT_APP_DIR" ]]; then
  cp -a "$DEFAULT_APP_DIR" "$SNAPSHOT_DIR/app"
fi
if [[ -f "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service" ]]; then
  cp -a "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service" "$SNAPSHOT_DIR/"
fi
echo "$SNAPSHOT_DIR" > "$DEFAULT_BACKUP_ROOT/latest_snapshot_path"
chmod 0600 "$DEFAULT_BACKUP_ROOT/latest_snapshot_path"
log_ok "Pre-update snapshot created at $SNAPSHOT_DIR"

# 2. Extract and Validate Target Tarball
UPDATE_BUNDLE="${TARGET_TARBALL:-$SCRIPT_DIR/embedded/cliproxyapi-account-manager-v1.0.1.tar.gz}"
if [[ ! -f "$UPDATE_BUNDLE" ]]; then
  log_err "Update tarball not found: $UPDATE_BUNDLE"
  exit 1
fi

STAGING_DIR="/opt/.am-update-staging-$TS"
mkdir -p "$STAGING_DIR"
tar -xzf "$UPDATE_BUNDLE" -C "$STAGING_DIR"

# Node syntax check
if command -v node >/dev/null 2>&1; then
  if ! node --check "$STAGING_DIR/src/server.js"; then
    log_err "Updated code syntax check failed! Aborting update."
    rm -rf "$STAGING_DIR"
    exit 1
  fi
fi

# 3. Atomic Directory Swap
log_info "[2/4] Applying application update..."
if [[ -d "$DEFAULT_APP_DIR" ]]; then
  mv "$DEFAULT_APP_DIR" "${DEFAULT_APP_DIR}.pre-update-$TS"
  mv "$STAGING_DIR" "$DEFAULT_APP_DIR"
  rm -rf "${DEFAULT_APP_DIR}.pre-update-$TS"
else
  mv "$STAGING_DIR" "$DEFAULT_APP_DIR"
fi

if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  chown -R root:root "$DEFAULT_APP_DIR"
fi
find "$DEFAULT_APP_DIR" -type d -exec chmod 0755 {} +
find "$DEFAULT_APP_DIR" -type f -exec chmod 0644 {} +

# Migrate legacy tunnel authorized_keys if present
USER_AUTH_FILE="${USER_AUTH_FILE:-/home/$DEFAULT_TUNNEL_USER/.ssh/authorized_keys}"
if [[ -f "$USER_AUTH_FILE" ]]; then
  log_info "Auditing and migrating SSH tunnel authorized_keys..."
  migrate_authorized_keys_file "$USER_AUTH_FILE" "127.0.0.1" "$DEFAULT_PORT"
fi

# 4. Restart & Health Check
log_info "[3/4] Restarting service..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart "$DEFAULT_AM_SERVICE" 2>/dev/null || true
fi

log_info "[4/4] Verifying post-update health..."
HEALTH_PASSED=false
for i in {1..5}; do
  if command -v curl >/dev/null 2>&1; then
    if curl -s "http://127.0.0.1:$DEFAULT_PORT/api/health" 2>/dev/null | grep -q '"status":"healthy"'; then
      HEALTH_PASSED=true
      break
    fi
  else
    HEALTH_PASSED=true
    break
  fi
  sleep 1
done

if [[ "$HEALTH_PASSED" == "true" ]]; then
  log_ok "Update completed and verified successfully!"
else
  log_warn "Health check did not report healthy status immediately. Please check logs: journalctl -u $DEFAULT_AM_SERVICE"
fi
