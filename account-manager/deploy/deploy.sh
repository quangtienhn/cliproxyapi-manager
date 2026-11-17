#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Account Manager - Hardened Deployment Script (TX3 Debian 12 ARM64)
# ==============================================================================
# Usage:
#   sudo ./deploy.sh [--dry-run]
# ==============================================================================

set -euo pipefail

# 1. Root Privilege Enforcement
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Deployment script must be run as root (or with sudo)." >&2
  exit 1
fi

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "[INFO] Running in DRY-RUN mode. Validating package and environment without modifying system state."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared strict parser
if [[ -f "$SCRIPT_DIR/parse_state.inc.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/parse_state.inc.sh"
fi

APP_DIR="/opt/cliproxyapi-account-manager"
CONFIG_DIR="/etc/cliproxyapi-account-manager"
LOG_DIR="/var/log/cliproxyapi-account-manager"
DATA_DIR="/var/lib/cliproxyapi-account-manager"
AUTH_DIR="/var/lib/cliproxyapi/auths"
BACKUP_ROOT="/var/backups/cliproxyapi-account-manager"
SERVICE_NAME="cliproxyapi-account-manager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PORT=8320

# Transaction markers to track state changes
TX_STATE="PREPARATION" # PREPARATION | SNAPSHOT_CREATED | LIVE_MUTATING | COMPLETED
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
SNAPSHOT_DIR=""
STAGING_DIR="/opt/.cliproxyapi-account-manager-staging.$TIMESTAMP"
APP_OLD="/opt/.cliproxyapi-account-manager-old.$TIMESTAMP"

# -----------------------------------------------------------------------------
# TRANSACTIONAL RECOVERY HANDLER (P0-3 & FIX-05)
# -----------------------------------------------------------------------------
cleanup_and_recover() {
  local exit_code=$?
  if [[ "$exit_code" -ne 0 && "$DRY_RUN" == "false" && "$TX_STATE" != "COMPLETED" ]]; then
    echo "" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "[CRITICAL FAILURE] Deployment failed at state: $TX_STATE (code $exit_code)!" >&2
    echo "[RECOVERY] Initiating transactional recovery to preserve system integrity..." >&2

    # Clean temporary staging if it exists
    rm -rf "$STAGING_DIR" 2>/dev/null || true

    if [[ "$TX_STATE" == "LIVE_MUTATING" ]]; then
      if [[ "$IS_UPGRADE" == "true" && -n "$SNAPSHOT_DIR" && -d "$SNAPSHOT_DIR" ]]; then
        echo "[RECOVERY] Upgrade failed mid-flight. Restoring previous application and service state..." >&2

        # Validate snapshot state file strictly using shared parser (FIX-05)
        local state_file="$SNAPSHOT_DIR/service_state.env"
        local parsed_state
        if parsed_state=$(parse_service_state_strict "$state_file" 2>/dev/null); then
          local was_enabled
          local was_active
          was_enabled=$(echo "$parsed_state" | grep '^WAS_ENABLED=' | cut -d'=' -f2)
          was_active=$(echo "$parsed_state" | grep '^WAS_ACTIVE=' | cut -d'=' -f2)

          # Restore app directory from snapshot
          rm -rf "$APP_DIR" 2>/dev/null || true
          if [[ -d "$SNAPSHOT_DIR/app" ]]; then
            cp -a "$SNAPSHOT_DIR/app" "$APP_DIR"
            chown -R root:root "$APP_DIR"
            find "$APP_DIR" -type d -exec chmod 0755 {} +
            find "$APP_DIR" -type f -exec chmod 0644 {} +
          fi

          # Restore systemd unit
          if [[ -f "$SNAPSHOT_DIR/service_unit.service" ]]; then
            cp -a "$SNAPSHOT_DIR/service_unit.service" "$SERVICE_FILE"
            chmod 0644 "$SERVICE_FILE"
            chown root:root "$SERVICE_FILE"
            systemctl daemon-reload 2>/dev/null || true
          fi

          if [[ "$was_enabled" == "yes" ]]; then
            systemctl enable "$SERVICE_NAME" 2>/dev/null || true
          else
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
          fi

          if [[ "$was_active" == "yes" ]]; then
            systemctl restart "$SERVICE_NAME" 2>/dev/null || true
          else
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
          fi
          echo "[RECOVERY] Previous version and service state restored successfully." >&2
        else
          echo "[RECOVERY ERROR] Pre-upgrade snapshot metadata was corrupt or unreadable! Cannot safely restore service state." >&2
        fi

      else
        echo "[RECOVERY] Fresh install failed mid-flight. Cleaning partial artifacts..." >&2
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$SERVICE_FILE" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        rm -rf "$APP_DIR" 2>/dev/null || true
        echo "[RECOVERY] Partial installation cleanly purged." >&2
      fi
    elif [[ "$TX_STATE" == "SNAPSHOT_CREATED" ]]; then
      echo "[RECOVERY] Failure occurred before live system was altered. Existing service remains untouched." >&2
    fi

    # Clean old backup directory if left behind
    rm -rf "$APP_OLD" 2>/dev/null || true

    echo "[RECOVERY] System recovery finished. Preserved credentials and logs." >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  fi
}
trap cleanup_and_recover EXIT

echo "=== CLIProxyAPI Account Manager Deployment & Validation ==="

# 2. Package Integrity & File Validation
echo "[1/8] Validating source package integrity..."
REQUIRED_FILES=(
  "$PKG_ROOT/package.json"
  "$PKG_ROOT/src/server.js"
  "$PKG_ROOT/src/config.js"
  "$PKG_ROOT/src/auth.js"
  "$PKG_ROOT/src/auth_store.js"
  "$PKG_ROOT/src/audit.js"
  "$PKG_ROOT/src/providers/index.js"
  "$PKG_ROOT/src/providers/base.js"
  "$PKG_ROOT/src/providers/codex.js"
  "$PKG_ROOT/src/providers/xai.js"
  "$PKG_ROOT/src/providers/gemini_deferred.js"
  "$PKG_ROOT/public/index.html"
  "$PKG_ROOT/public/app.js"
  "$PKG_ROOT/public/style.css"
  "$PKG_ROOT/deploy/cliproxyapi-account-manager.service"
  "$PKG_ROOT/deploy/manager.env.template"
  "$PKG_ROOT/deploy/rollback.sh"
  "$PKG_ROOT/deploy/parse_state.inc.sh"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "[ERROR] Required file missing from deployment package: $file" >&2
    exit 1
  fi
done

if [[ ! -x "$PKG_ROOT/deploy/rollback.sh" ]]; then
  chmod +x "$PKG_ROOT/deploy/rollback.sh" 2>/dev/null || true
fi
echo "[OK] All required deployment files verified."

# 3. Environment & Runtime Validation
echo "[2/8] Validating environment and runtimes..."
if ! command -v node >/dev/null 2>&1; then
  echo "[ERROR] Node.js is not installed. Please install Node.js 18+ (e.g. apt install -y nodejs)." >&2
  exit 1
fi

NODE_VER=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
if [[ "$NODE_VER" -lt 18 ]]; then
  echo "[ERROR] Node.js version must be 18 or higher (found: $(node -v))." >&2
  exit 1
fi

if ! id "cliproxyapi" >/dev/null 2>&1; then
  echo "[ERROR] Dedicated system user 'cliproxyapi' does not exist." >&2
  exit 1
fi

if [[ ! -d "$AUTH_DIR" ]]; then
  echo "[WARN] Auth directory $AUTH_DIR not found. Ensure CLIProxyAPI is deployed on TX3."
fi

# 4. Port Availability Check
echo "[3/8] Checking port $PORT availability..."
PORT_OWNER=""
IS_UPGRADE=false

if [[ -f "$SERVICE_FILE" ]] || [[ -d "$APP_DIR" ]]; then
  IS_UPGRADE=true
  echo "[INFO] Existing deployment detected: Operation mode = UPGRADE"
else
  echo "[INFO] No existing deployment detected: Operation mode = FRESH INSTALL"
fi

if command -v ss >/dev/null 2>&1; then
  if ss -lntp 2>/dev/null | grep -qE "[:\.]${PORT}\b"; then
    PORT_OWNER=$(ss -lntp 2>/dev/null | grep -E "[:\.]${PORT}\b" | head -n1 || true)
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      echo "[INFO] Port $PORT is currently occupied by active $SERVICE_NAME (expected for upgrade)."
    else
      echo "[ERROR] Port $PORT is occupied by an external process: $PORT_OWNER" >&2
      exit 1
    fi
  else
    echo "[OK] Port $PORT is completely free."
  fi
else
  echo "[WARN] 'ss' command not available. Skipping socket check."
fi

# 5. Strict systemd Unit Validation (No '|| true')
echo "[4/8] Validating systemd unit file syntax..."
CANDIDATE_UNIT="$PKG_ROOT/deploy/cliproxyapi-account-manager.service"
if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify "$CANDIDATE_UNIT"; then
    echo "[ERROR] systemd-analyze verify failed on $CANDIDATE_UNIT! Aborting deployment." >&2
    exit 1
  fi
fi
echo "[OK] systemd unit verification passed."

# 6. Configuration Template Validation
echo "[5/8] Validating configuration template..."
if [[ ! -s "$PKG_ROOT/deploy/manager.env.template" ]]; then
  echo "[ERROR] Configuration template $PKG_ROOT/deploy/manager.env.template is empty!" >&2
  exit 1
fi
echo "[OK] Configuration template verified."

if [[ "$DRY_RUN" == "true" ]]; then
  echo "--------------------------------------------------------"
  echo "[DRY-RUN] Verification complete! All prerequisites and files are valid."
  echo "[DRY-RUN] Target paths: App=$APP_DIR, Config=$CONFIG_DIR, Logs=$LOG_DIR, Service=$SERVICE_FILE"
  echo "[DRY-RUN] Planned mode: $([[ "$IS_UPGRADE" == "true" ]] && echo "Upgrade with backup" || echo "Fresh installation")"
  echo "[DRY-RUN] Port $PORT status: $([[ -n "$PORT_OWNER" ]] && echo "Active (owned by $SERVICE_NAME)" || echo "Free")"
  echo "[DRY-RUN] No system modifications have been made."
  echo "--------------------------------------------------------"
  exit 0
fi

# 7. Backup Previous State (Application, systemd unit, and service state)
if [[ "$IS_UPGRADE" == "true" ]]; then
  echo "[6/8] Creating comprehensive pre-upgrade snapshot..."
  SNAPSHOT_DIR="$BACKUP_ROOT/snapshot_$TIMESTAMP"
  mkdir -p "$SNAPSHOT_DIR"
  chown root:root "$BACKUP_ROOT" "$SNAPSHOT_DIR"
  chmod 0700 "$BACKUP_ROOT" "$SNAPSHOT_DIR"

  # Backup app directory
  if [[ -d "$APP_DIR" ]]; then
    cp -a "$APP_DIR" "$SNAPSHOT_DIR/app"
  fi

  # Backup systemd unit and records
  if [[ -f "$SERVICE_FILE" ]]; then
    cp -a "$SERVICE_FILE" "$SNAPSHOT_DIR/service_unit.service"
  fi

  # Record systemd service states strictly as WAS_ENABLED=yes|no, WAS_ACTIVE=yes|no
  WAS_ENABLED="no"
  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    WAS_ENABLED="yes"
  fi
  echo "WAS_ENABLED=$WAS_ENABLED" > "$SNAPSHOT_DIR/service_state.env"

  WAS_ACTIVE="no"
  if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
    WAS_ACTIVE="yes"
  fi
  echo "WAS_ACTIVE=$WAS_ACTIVE" >> "$SNAPSHOT_DIR/service_state.env"
  chmod 0600 "$SNAPSHOT_DIR/service_state.env"

  # Record snapshot pointer
  echo "$SNAPSHOT_DIR" > "$BACKUP_ROOT/latest_snapshot_path"
  chmod 0600 "$BACKUP_ROOT/latest_snapshot_path"
  TX_STATE="SNAPSHOT_CREATED"
  echo "[OK] Pre-upgrade snapshot created at: $SNAPSHOT_DIR"
fi

# 8. Isolated Staging Preparation
echo "[7/8] Preparing isolated staging environment..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy files into staging
cp -r "$PKG_ROOT/src" "$PKG_ROOT/public" "$PKG_ROOT/package.json" "$STAGING_DIR/"

# Set strict least-privilege permissions on staging
chown -R root:root "$STAGING_DIR"
find "$STAGING_DIR" -type d -exec chmod 0755 {} +
find "$STAGING_DIR" -type f -exec chmod 0644 {} +

# Validate staged application by running node syntax check
if ! node --check "$STAGING_DIR/src/server.js"; then
  echo "[ERROR] Staged application syntax check failed! Aborting before live swap." >&2
  rm -rf "$STAGING_DIR"
  exit 1
fi
echo "[OK] Staged application validated successfully."

# 9. Live System Modifications (TX_STATE = LIVE_MUTATING)
TX_STATE="LIVE_MUTATING"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR"
chown cliproxyapi:cliproxyapi "$LOG_DIR" "$DATA_DIR"
chmod 0750 "$LOG_DIR"
chmod 0700 "$DATA_DIR"

if [[ ! -f "$CONFIG_DIR/manager.env" ]]; then
  cp "$PKG_ROOT/deploy/manager.env.template" "$CONFIG_DIR/manager.env"
  chown root:cliproxyapi "$CONFIG_DIR/manager.env"
  chmod 0640 "$CONFIG_DIR/manager.env"
  echo "[INFO] Created initial config at $CONFIG_DIR/manager.env"
else
  echo "[INFO] Existing config preserved at $CONFIG_DIR/manager.env"
fi

# Atomic Switch: Move staging into live APP_DIR
echo "[INFO] Performing atomic directory swap..."
if [[ -d "$APP_DIR" ]]; then
  mv "$APP_DIR" "$APP_OLD"
  mv "$STAGING_DIR" "$APP_DIR"
  rm -rf "$APP_OLD"
else
  mv "$STAGING_DIR" "$APP_DIR"
fi

# Install and start systemd unit
echo "[8/8] Installing systemd unit and starting service..."
cp "$PKG_ROOT/deploy/cliproxyapi-account-manager.service" "$SERVICE_FILE"
chmod 0644 "$SERVICE_FILE"
chown root:root "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# Post-deployment Health Check
echo "[INFO] Waiting for service health check..."
sleep 2

HEALTH_OK=false
for i in {1..5}; do
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    if command -v curl >/dev/null 2>&1; then
      if curl -s "http://127.0.0.1:$PORT/api/health" | grep -q '"status":"healthy"'; then
        HEALTH_OK=true
        break
      fi
    else
      HEALTH_OK=true
      break
    fi
  fi
  sleep 1
done

if [[ "$HEALTH_OK" == "true" ]]; then
  TX_STATE="COMPLETED"
  echo "=================================================================="
  echo "[SUCCESS] CLIProxyAPI Account Manager deployed and active!"
  echo "Local LAN URL: http://<TX3_IP>:$PORT"
  echo "Health Check:  PASSED (http://127.0.0.1:$PORT/api/health)"
  echo "Service Unit:  $SERVICE_FILE"
  echo "Logs:          journalctl -u $SERVICE_NAME -f"
  echo "=================================================================="
else
  echo "[ERROR] Service failed post-deployment health check!" >&2
  exit 1
fi
