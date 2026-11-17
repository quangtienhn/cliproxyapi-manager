#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Account Manager - Hardened Rollback Script (TX3 Debian 12 ARM64)
# ==============================================================================
# Usage:
#   sudo ./rollback.sh [--uninstall]
#
# Modes:
#   Default (no flags): Restores previous working version from snapshot.
#                       Aborts safely if no valid snapshot is available.
#   --uninstall:        Explicit uninstallation of the service.
# ==============================================================================

set -euo pipefail

# 1. Root Privilege Enforcement
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Rollback script must be run as root (or with sudo)." >&2
  exit 1
fi

UNINSTALL_MODE=false
if [[ "${1:-}" == "--uninstall" ]]; then
  UNINSTALL_MODE=true
  echo "[INFO] Running in explicit UNINSTALL mode."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cliproxyapi-account-manager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
APP_DIR="/opt/cliproxyapi-account-manager"
CONFIG_DIR="/etc/cliproxyapi-account-manager"
LOG_DIR="/var/log/cliproxyapi-account-manager"
DATA_DIR="/var/lib/cliproxyapi-account-manager"
BACKUP_ROOT="/var/backups/cliproxyapi-account-manager"
POINTER_FILE="$BACKUP_ROOT/latest_snapshot_path"

# Source shared strict parser
if [[ -f "$SCRIPT_DIR/parse_state.inc.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/parse_state.inc.sh"
fi

echo "=== CLIProxyAPI Account Manager Rollback & State Restoration ==="

# -----------------------------------------------------------------------------
# PHASE 1: VALIDATION BEFORE ANY SYSTEM MODIFICATION
# Current service is NOT touched until all snapshot components pass validation.
# -----------------------------------------------------------------------------

SNAPSHOT_DIR=""
RESTORE_UPGRADE=false
WAS_ENABLED=""
WAS_ACTIVE=""

if [[ "$UNINSTALL_MODE" == "false" ]]; then
  echo "[1/4] Validating pre-upgrade snapshot and state integrity..."

  # Step 1.1: Verify pointer file exists and is a regular file (NOT a symlink)
  if [[ ! -e "$POINTER_FILE" ]]; then
    echo "[ERROR] Snapshot pointer file not found: $POINTER_FILE" >&2
    echo "[ABORT] No pre-upgrade snapshot available to restore. Active service remains untouched." >&2
    echo "If you intend to completely remove the application, run: sudo ./rollback.sh --uninstall" >&2
    exit 1
  fi

  if [[ -L "$POINTER_FILE" ]]; then
    echo "[ERROR] Security violation: Snapshot pointer file is a symlink: $POINTER_FILE" >&2
    exit 1
  fi

  RAW_PTR=$(cat "$POINTER_FILE" | tr -d '\r\n')
  if [[ -z "$RAW_PTR" ]]; then
    echo "[ERROR] Snapshot pointer file is empty!" >&2
    exit 1
  fi

  # Step 1.2: Validate Backup Root ownership and permissions
  if [[ -d "$BACKUP_ROOT" ]]; then
    ROOT_PERMS=$(stat -c '%u:%g:%a' "$BACKUP_ROOT" 2>/dev/null || stat -f '%u:%g:%p' "$BACKUP_ROOT" 2>/dev/null || echo "0:0:700")
    ROOT_OWNER=$(echo "$ROOT_PERMS" | cut -d':' -f1,2)
    if [[ "$ROOT_OWNER" != "0:0" ]]; then
      echo "[ERROR] Security violation: Backup root $BACKUP_ROOT is not owned by root:root (found $ROOT_OWNER)!" >&2
      exit 1
    fi
  fi

  # Step 1.3: Canonicalize paths and enforce strict location under BACKUP_ROOT
  REAL_ROOT=$(realpath -m "$BACKUP_ROOT")
  REAL_PTR=$(realpath -m "$RAW_PTR")

  if [[ ! -d "$REAL_PTR" ]]; then
    echo "[ERROR] Snapshot directory does not exist: $REAL_PTR" >&2
    exit 1
  fi

  if [[ "$REAL_PTR" != "$REAL_ROOT"/snapshot_* ]]; then
    echo "[ERROR] Security violation: Snapshot path is outside designated backup root: $REAL_PTR" >&2
    exit 1
  fi

  # Step 1.4: Check for unexpected symlinks anywhere in the snapshot tree
  if [[ -L "$REAL_PTR" ]]; then
    echo "[ERROR] Security violation: Snapshot directory itself is a symlink!" >&2
    exit 1
  fi

  # Scan snapshot directory tree for any symbolic links
  if find "$REAL_PTR" -type l 2>/dev/null | grep -q .; then
    echo "[ERROR] Security violation: Snapshot contains symbolic links inside the tree!" >&2
    exit 1
  fi

  # Step 1.5: Validate snapshot directory ownership (root:root) and permissions
  DIR_PERMS=$(stat -c '%u:%g' "$REAL_PTR" 2>/dev/null || stat -f '%u:%g' "$REAL_PTR" 2>/dev/null || echo "0:0")
  if [[ "$DIR_PERMS" != "0:0" ]]; then
    echo "[ERROR] Security violation: Snapshot directory is not owned by root:root (found $DIR_PERMS)!" >&2
    exit 1
  fi

  # Step 1.6: Validate required components exist
  if [[ ! -d "$REAL_PTR/app" ]] || [[ ! -f "$REAL_PTR/service_unit.service" ]] || [[ ! -f "$REAL_PTR/service_state.env" ]]; then
    echo "[ERROR] Incomplete snapshot directory! Missing required files in $REAL_PTR." >&2
    exit 1
  fi

  # Step 1.7: STRICT DATA PARSING of service_state.env (FIX-01: NO SHELL SOURCING, SAFE MATH)
  STATE_FILE="$REAL_PTR/service_state.env"
  PARSED_OUTPUT=$(parse_service_state_strict "$STATE_FILE") || {
    echo "[ERROR] Snapshot service_state.env failed strict validation!" >&2
    exit 1
  }

  WAS_ENABLED=$(echo "$PARSED_OUTPUT" | grep '^WAS_ENABLED=' | cut -d'=' -f2)
  WAS_ACTIVE=$(echo "$PARSED_OUTPUT" | grep '^WAS_ACTIVE=' | cut -d'=' -f2)

  if [[ -z "$WAS_ENABLED" || -z "$WAS_ACTIVE" ]]; then
    echo "[ERROR] Could not extract valid WAS_ENABLED / WAS_ACTIVE from parsed state!" >&2
    exit 1
  fi

  SNAPSHOT_DIR="$REAL_PTR"
  RESTORE_UPGRADE=true
  echo "[OK] Pre-upgrade snapshot verified. State: enabled=$WAS_ENABLED, active=$WAS_ACTIVE."
fi

# -----------------------------------------------------------------------------
# PHASE 2: ATOMIC RESTORATION OR UNINSTALLATION
# Reaching this point guarantees validation has succeeded.
# -----------------------------------------------------------------------------

echo "[2/4] Stopping active service..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

if [[ "$RESTORE_UPGRADE" == "true" ]]; then
  echo "[3/4] Restoring application files from verified snapshot..."
  rm -rf "$APP_DIR"
  cp -a "$SNAPSHOT_DIR/app" "$APP_DIR"
  chown -R root:root "$APP_DIR"
  find "$APP_DIR" -type d -exec chmod 0755 {} +
  find "$APP_DIR" -type f -exec chmod 0644 {} +

  echo "[3/4] Restoring previous systemd unit and service state..."
  cp -a "$SNAPSHOT_DIR/service_unit.service" "$SERVICE_FILE"
  chmod 0644 "$SERVICE_FILE"
  chown root:root "$SERVICE_FILE"
  systemctl daemon-reload

  if [[ "$WAS_ENABLED" == "yes" ]]; then
    systemctl enable "$SERVICE_NAME" 2>/dev/null || true
  else
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  fi

  if [[ "$WAS_ACTIVE" == "yes" ]]; then
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    echo "[OK] Previous active service state restored."
  else
    echo "[OK] Previous inactive service state maintained."
  fi

  # Clean pointer file
  rm -f "$POINTER_FILE"
  echo "[SUCCESS] Successfully restored previous working application version."

else
  # Explicit uninstall mode
  echo "[3/4] Executing clean application uninstallation..."
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
  fi
  rm -rf "$APP_DIR"
  rm -f "$POINTER_FILE"
  echo "[SUCCESS] Account Manager application and service unit cleanly removed."
fi

# -----------------------------------------------------------------------------
# PHASE 3: PRESERVATION GUARANTEES
# -----------------------------------------------------------------------------
echo "[4/4] Preserving configuration, state data, logs, and CLIProxyAPI credentials..."
echo "Configuration files preserved at: $CONFIG_DIR"
echo "Persistent state preserved at: $DATA_DIR"
echo "Audit logs preserved at: $LOG_DIR"
echo "CLIProxyAPI auth directory (/var/lib/cliproxyapi/auths) 100% untouched."
echo "CLIProxyAPI service (cliproxyapi.service) 100% untouched."

echo "=================================================================="
echo "[COMPLETE] Operation finished safely."
echo "=================================================================="
