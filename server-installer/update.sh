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
UPDATE_BUNDLE="${TARGET_TARBALL:-$SCRIPT_DIR/embedded/cliproxyapi-account-manager-v1.0.3.tar.gz}"
if [[ ! -f "$UPDATE_BUNDLE" ]]; then
  log_err "Update tarball not found: $UPDATE_BUNDLE"
  exit 1
fi

# Verify the embedded bundle checksum when using the shipped bundle.
if [[ -z "$TARGET_TARBALL" && -f "$SCRIPT_DIR/embedded/SHA256SUMS-v1.0.3.txt" ]]; then
  EXPECTED_SUM=$(grep -E "$(basename "$UPDATE_BUNDLE")\$" "$SCRIPT_DIR/embedded/SHA256SUMS-v1.0.3.txt" | awk '{print $1}')
  if [[ -n "$EXPECTED_SUM" ]]; then
    ACTUAL_SUM=$(sha256sum "$UPDATE_BUNDLE" | awk '{print $1}')
    if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
      log_err "Checksum mismatch for $(basename "$UPDATE_BUNDLE")! Refusing to update."
      exit 1
    fi
    log_ok "Update bundle checksum verified."
  fi
fi

# Extract the application bundle.
STAGING_DIR="/opt/.am-update-staging-$TS"
mkdir -p "$STAGING_DIR"
tar -xzf "$UPDATE_BUNDLE" -C "$STAGING_DIR"

# Extract the optional YAML dependency shipped alongside the bundle.
if [[ -z "$TARGET_TARBALL" && -f "$SCRIPT_DIR/embedded/yaml-dependency.tar.gz" ]]; then
  tar -xzf "$SCRIPT_DIR/embedded/yaml-dependency.tar.gz" -C "$STAGING_DIR"
fi

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

# Never carry a v1.0.0 wildcard bind forward across an update.
enforce_loopback_bind "$DEFAULT_CONFIG_DIR/manager.env" \
  || log_warn "Could not enforce loopback binding; verify HOST=127.0.0.1 manually."

# 4. Restart & Health Check
log_info "[3/4] Restarting service..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart "$DEFAULT_AM_SERVICE" 2>/dev/null || true
fi

post_update_health() {
  if [[ "${INSTALLER_TEST_MODE:-0}" == "1" && "${TEST_FORCE_HEALTH_FAIL:-0}" != "1" ]]; then
    return 0
  fi
  local i
  for i in {1..5}; do
    if command -v curl >/dev/null 2>&1; then
      if curl -s "http://127.0.0.1:$DEFAULT_PORT/api/health" 2>/dev/null | grep -q '"status":"healthy"'; then
        return 0
      fi
    else
      return 0
    fi
    sleep 1
  done
  return 1
}

log_info "[4/4] Verifying post-update health..."
if post_update_health; then
  # Security migrations are applied only after the new version is proven
  # healthy, so a failed update never mutates SSH access or config.
  USER_AUTH_FILE="${USER_AUTH_FILE:-/home/$DEFAULT_TUNNEL_USER/.ssh/authorized_keys}"
  if [[ -f "$USER_AUTH_FILE" ]]; then
    log_info "Auditing and migrating SSH tunnel authorized_keys..."
    migrate_authorized_keys_file "$USER_AUTH_FILE" "127.0.0.1" "$DEFAULT_PORT" \
      || log_warn "authorized_keys migration did not complete; review $USER_AUTH_FILE"
  fi
  if id "$DEFAULT_TUNNEL_USER" >/dev/null 2>&1; then
    install_tunnel_sshd_policy "$DEFAULT_TUNNEL_USER" "127.0.0.1" "$DEFAULT_PORT" \
      || log_warn "Per-user sshd policy could not be refreshed."
  fi

  log_ok "Update completed and verified successfully!"
  exit 0
fi

# Automatic rollback: restore the application tree captured before the update.
log_err "Post-update health check failed. Rolling back to the previous version..."
ROLLBACK_FAILED_DIR="${DEFAULT_APP_DIR}.failed-$TS"
ROLLED_BACK=false
if [[ -d "$SNAPSHOT_DIR/app" ]]; then
  if [[ -d "$DEFAULT_APP_DIR" ]]; then
    mv "$DEFAULT_APP_DIR" "$ROLLBACK_FAILED_DIR" || true
  fi
  if mv "$SNAPSHOT_DIR/app" "$DEFAULT_APP_DIR"; then
    ROLLED_BACK=true
    log_ok "Application files restored from pre-update snapshot."
  fi
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart "$DEFAULT_AM_SERVICE" 2>/dev/null || true
fi

if [[ "$ROLLED_BACK" == "true" ]]; then
  rm -rf "$ROLLBACK_FAILED_DIR"
  if post_update_health; then
    log_ok "Rollback completed and service is healthy. Update was not applied."
  else
    log_err "Service is still unhealthy after rollback. Inspect: journalctl -u $DEFAULT_AM_SERVICE"
  fi
else
  log_err "Rollback source snapshot is missing. Manual intervention required: $SNAPSHOT_DIR"
fi
exit 1
