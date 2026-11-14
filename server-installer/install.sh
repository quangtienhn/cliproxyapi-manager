#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Server Installation Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
COMMON_DIR="$SCRIPT_DIR/../common"
EMBEDDED_DIR="$SCRIPT_DIR/embedded"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

# shellcheck source=/dev/null
source "$COMMON_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/installer_core.sh"

NON_INTERACTIVE=false
DRY_RUN=false
SETUP_TUNNEL_USER=false
TUNNEL_PUBKEY=""

usage() {
  cat << 'EOF'
CLIProxyAPI Account Manager Easy Installer
Usage:
  sudo ./install.sh [options]

Options:
  --non-interactive     Run without interactive prompts (default values used)
  --dry-run             Validate prerequisites without mutating system
  --setup-tunnel-user   Create dedicated restricted SSH tunnel user (amtunnel)
  --tunnel-pubkey KEY   Pass SSH public key string for tunnel authentication
  -h, --help            Show this help message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --setup-tunnel-user) SETUP_TUNNEL_USER=true; shift ;;
    --tunnel-pubkey) TUNNEL_PUBKEY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_err "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 && "$DRY_RUN" == "false" && "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  log_err "Installer must be run as root (or with sudo)."
  exit 1
fi

echo "=================================================================="
echo "    CLIProxyAPI Account Manager - Easy Installer v1.0.1          "
echo "=================================================================="

# 1. Prerequisites Check
log_info "[1/7] Validating operating system and prerequisites..."
if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  check_prerequisites
fi

# 2. Package & Archive Verification
log_info "[2/7] Verifying embedded package bundle integrity..."
BUNDLE_FILE="$EMBEDDED_DIR/cliproxyapi-account-manager-v1.0.1.tar.gz"
CHECKSUM_FILE="$EMBEDDED_DIR/SHA256SUMS-v1.0.1.txt"

if [[ ! -f "$BUNDLE_FILE" ]]; then
  log_err "Embedded application bundle not found: $BUNDLE_FILE"
  exit 1
fi

if [[ -f "$CHECKSUM_FILE" ]]; then
  BUNDLE_NAME=$(basename "$BUNDLE_FILE")
  EXPECTED_SUM=$(grep -E "${BUNDLE_NAME}\$" "$CHECKSUM_FILE" | awk '{print $1}')
  if [[ -n "$EXPECTED_SUM" ]]; then
    ACTUAL_SUM=$(sha256sum "$BUNDLE_FILE" | awk '{print $1}')
    if [[ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]]; then
      log_err "Checksum mismatch for $BUNDLE_NAME! Expected: $EXPECTED_SUM, got: $ACTUAL_SUM"
      exit 1
    fi
    log_ok "Bundle checksum verified successfully."
  fi
fi

# 3. Detect existing deployment
log_info "[3/7] Checking for existing installation..."
IS_UPGRADE=false
if [[ -d "$DEFAULT_APP_DIR" || -f "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service" ]]; then
  IS_UPGRADE=true
  log_info "Existing deployment detected. Operating mode: UPGRADE"
else
  log_info "No prior installation detected. Operating mode: FRESH INSTALL"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log_ok "[DRY-RUN] Pre-flight checks passed. No system changes made."
  exit 0
fi

# 4. User and Directory Provisioning
log_info "[4/7] Ensuring system users and directories exist..."
if ! id "cliproxyapi" >/dev/null 2>&1; then
  log_info "Creating system user 'cliproxyapi'..."
  useradd -r -s /bin/false -d /var/lib/cliproxyapi cliproxyapi 2>/dev/null || true
fi

mkdir -p "$DEFAULT_CONFIG_DIR" "$DEFAULT_LOG_DIR" "$DEFAULT_DATA_DIR" "$DEFAULT_BACKUP_ROOT"
if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  chown -R cliproxyapi:cliproxyapi "$DEFAULT_LOG_DIR" "$DEFAULT_DATA_DIR"
fi
chmod 0750 "$DEFAULT_LOG_DIR"
chmod 0700 "$DEFAULT_DATA_DIR" "$DEFAULT_BACKUP_ROOT"

# Pre-upgrade backup if upgrading
if [[ "$IS_UPGRADE" == "true" ]]; then
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
  log_ok "Pre-upgrade snapshot saved at $SNAPSHOT_DIR"
fi

# 5. Extract and Deploy Application
log_info "[5/7] Deploying Account Manager application..."
STAGING_DIR="/opt/.am-staging-$(date +%s)"
mkdir -p "$STAGING_DIR"
tar -xzf "$BUNDLE_FILE" -C "$STAGING_DIR"

# Extract yaml dependency if present
if [[ -f "$EMBEDDED_DIR/yaml-dependency.tar.gz" ]]; then
  tar -xzf "$EMBEDDED_DIR/yaml-dependency.tar.gz" -C "$STAGING_DIR"
fi

# Validate staged node files
if command -v node >/dev/null 2>&1; then
  if ! node --check "$STAGING_DIR/src/server.js"; then
    log_err "Staged code syntax check failed! Aborting."
    rm -rf "$STAGING_DIR"
    exit 1
  fi
fi

# Atomic directory swap
mkdir -p "$(dirname "$DEFAULT_APP_DIR")"
if [[ -d "$DEFAULT_APP_DIR" ]]; then
  mv "$DEFAULT_APP_DIR" "${DEFAULT_APP_DIR}.old-$$"
  mv "$STAGING_DIR" "$DEFAULT_APP_DIR"
  rm -rf "${DEFAULT_APP_DIR}.old-$$"
else
  mv "$STAGING_DIR" "$DEFAULT_APP_DIR"
fi

if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
  chown -R root:root "$DEFAULT_APP_DIR"
fi
find "$DEFAULT_APP_DIR" -type d -exec chmod 0755 {} +
find "$DEFAULT_APP_DIR" -type f -exec chmod 0644 {} +

# 6. Configure Environment and Secrets
log_info "[6/7] Managing configuration and Management API secrets..."
if [[ ! -f "$DEFAULT_CONFIG_DIR/manager.env" ]]; then
  if [[ -f "$TEMPLATES_DIR/manager.env.template" ]]; then
    cp "$TEMPLATES_DIR/manager.env.template" "$DEFAULT_CONFIG_DIR/manager.env"
  else
    cat << EOF > "$DEFAULT_CONFIG_DIR/manager.env"
PORT=8320
HOST=127.0.0.1
CLIPROXYAPI_URL=http://127.0.0.1:8317
AUTH_DIR=/var/lib/cliproxyapi/auths
EOF
  fi
  if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
    chown root:cliproxyapi "$DEFAULT_CONFIG_DIR/manager.env"
  fi
  chmod 0640 "$DEFAULT_CONFIG_DIR/manager.env"
  log_ok "Generated fresh secure configuration at $DEFAULT_CONFIG_DIR/manager.env"
else
  log_ok "Preserved existing configuration at $DEFAULT_CONFIG_DIR/manager.env"
fi

# v1.0.0 installations may still pin HOST=0.0.0.0. Force loopback-only.
enforce_loopback_bind "$DEFAULT_CONFIG_DIR/manager.env" || log_warn "Could not enforce loopback binding; verify HOST=127.0.0.1 manually."

# Synchronize secret with CLIProxyAPI if present
if [[ -f "$DEFAULT_APP_DIR/src/sync_secret.js" && -f "$DEFAULT_CLIPROXY_CONFIG" ]]; then
  log_info "Synchronizing Management API secret with CLIProxyAPI config..."
  node "$DEFAULT_APP_DIR/src/sync_secret.js" "$DEFAULT_CLIPROXY_CONFIG" "$DEFAULT_CONFIG_DIR/manager.env" \
    || log_warn "Secret synchronization exited with non-zero status (verify CLIPROXYAPI_MANAGEMENT_KEY manually)"
fi

# Setup restricted tunnel user if requested
if [[ "$SETUP_TUNNEL_USER" == "true" ]]; then
  log_info "Setting up restricted SSH tunnel user '$DEFAULT_TUNNEL_USER'..."
  if ! id "$DEFAULT_TUNNEL_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/false -d "/home/$DEFAULT_TUNNEL_USER" -m "$DEFAULT_TUNNEL_USER" 2>/dev/null || true
  fi
  USER_SSH_DIR="/home/$DEFAULT_TUNNEL_USER/.ssh"
  mkdir -p "$USER_SSH_DIR"
  chmod 0700 "$USER_SSH_DIR"
  if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
    chown "$DEFAULT_TUNNEL_USER:$DEFAULT_TUNNEL_USER" "$USER_SSH_DIR"
  fi

  USER_AUTH_FILE="$USER_SSH_DIR/authorized_keys"
  if [[ -n "$TUNNEL_PUBKEY" ]]; then
    append_restricted_authorized_key "$USER_AUTH_FILE" "$TUNNEL_PUBKEY" "127.0.0.1" "$DEFAULT_PORT" \
      || { log_err "Failed to install tunnel public key."; exit 1; }
  fi

  # Migrate any v1.0.0 legacy key already present for this target.
  if [[ -f "$USER_AUTH_FILE" ]]; then
    migrate_authorized_keys_file "$USER_AUTH_FILE" "127.0.0.1" "$DEFAULT_PORT" \
      || log_warn "Legacy authorized_keys migration did not complete; review $USER_AUTH_FILE"
    if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
      chown "$DEFAULT_TUNNEL_USER:$DEFAULT_TUNNEL_USER" "$USER_AUTH_FILE"
    fi
  fi

  # Server-side forwarding lockdown for this user only.
  install_tunnel_sshd_policy "$DEFAULT_TUNNEL_USER" "127.0.0.1" "$DEFAULT_PORT" \
    || log_warn "Per-user sshd policy was not installed. The key-level permitopen/permitlisten restrictions remain active."

  if [[ -f "$USER_AUTH_FILE" ]]; then
    log_ok "Restricted SSH tunnel authorized_keys configured for $DEFAULT_TUNNEL_USER"
  fi
fi

# 7. Systemd Service Installation
log_info "[7/7] Configuring and starting systemd service..."
if [[ -f "$TEMPLATES_DIR/cliproxyapi-account-manager.service" && -d "/etc/systemd/system" ]]; then
  cp "$TEMPLATES_DIR/cliproxyapi-account-manager.service" "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service"
  chmod 0644 "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service"
  chown root:root "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service"
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable "$DEFAULT_AM_SERVICE" 2>/dev/null || true
  systemctl restart "$DEFAULT_AM_SERVICE" 2>/dev/null || true
fi

# Install CLI management symlink
CLI_BIN="/usr/local/bin/cliproxy-manager"
if [[ -f "$SCRIPT_DIR/bin/cliproxy-manager" ]]; then
  chmod +x "$SCRIPT_DIR/bin/cliproxy-manager"
  ln -sf "$SCRIPT_DIR/bin/cliproxy-manager" "$CLI_BIN" 2>/dev/null || true
fi

echo "=================================================================="
log_ok "CLIProxyAPI Account Manager installation completed successfully!"
echo "Management CLI: cliproxy-manager (or $SCRIPT_DIR/bin/cliproxy-manager)"
echo "Service status: systemctl status $DEFAULT_AM_SERVICE"
echo "Local UI port:  $DEFAULT_PORT (loopback only by default)"
echo "=================================================================="
