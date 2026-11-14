#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Safe Backup Script
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
  log_err "Backup script must be run as root (or with sudo)."
  exit 1
fi

BACKUP_PARENT="${BACKUP_DIR:-$DEFAULT_BACKUP_ROOT}"
TS="$(date +%Y%m%dT%H%M%S)"
TARGET_BACKUP="${BACKUP_PARENT}/backup_${TS}"

log_info "Creating secure backup package at $TARGET_BACKUP..."

mkdir -p "$TARGET_BACKUP"
chmod 0700 "$TARGET_BACKUP"

# 1. Back up Account Manager Configuration
if [[ -d "$DEFAULT_CONFIG_DIR" ]]; then
  mkdir -p "$TARGET_BACKUP/config"
  cp -a "$DEFAULT_CONFIG_DIR"/. "$TARGET_BACKUP/config/" 2>/dev/null || true
  chmod 0600 "$TARGET_BACKUP/config"/* 2>/dev/null || true
fi

# 2. Back up CLIProxyAPI Configuration & OAuth tokens (Protected)
if [[ -f "$DEFAULT_CLIPROXY_CONFIG" ]]; then
  mkdir -p "$TARGET_BACKUP/cliproxyapi"
  cp -a "$DEFAULT_CLIPROXY_CONFIG" "$TARGET_BACKUP/cliproxyapi/config.yaml"
  chmod 0600 "$TARGET_BACKUP/cliproxyapi/config.yaml"
fi

if [[ -d "$DEFAULT_AUTH_DIR" ]]; then
  mkdir -p "$TARGET_BACKUP/auths"
  cp -a "$DEFAULT_AUTH_DIR"/* "$TARGET_BACKUP/auths/" 2>/dev/null || true
  chmod -R 0600 "$TARGET_BACKUP/auths"/* 2>/dev/null || true
fi

# 3. Back up tunnel SSH material for operator reference. Restore does not
# write these files back automatically; they let an administrator rebuild the
# restricted access after disaster recovery.
TUNNEL_AUTH_FILE="/home/$DEFAULT_TUNNEL_USER/.ssh/authorized_keys"
if [[ -f "$TUNNEL_AUTH_FILE" ]]; then
  mkdir -p "$TARGET_BACKUP/ssh"
  cp -a "$TUNNEL_AUTH_FILE" "$TARGET_BACKUP/ssh/authorized_keys"
  chmod 0600 "$TARGET_BACKUP/ssh/authorized_keys"
fi
if [[ -f "${SSHD_CONFIG_PATH:-/etc/ssh/sshd_config}" ]]; then
  mkdir -p "$TARGET_BACKUP/ssh"
  awk '/# BEGIN cliproxyapi-account-manager tunnel policy/,/# END cliproxyapi-account-manager tunnel policy/' \
    "${SSHD_CONFIG_PATH:-/etc/ssh/sshd_config}" > "$TARGET_BACKUP/ssh/sshd_policy.conf" 2>/dev/null || true
  chmod 0600 "$TARGET_BACKUP/ssh/sshd_policy.conf"
fi

# 4. Back up Systemd Service Unit
if [[ -f "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service" ]]; then
  cp -a "/etc/systemd/system/${DEFAULT_AM_SERVICE}.service" "$TARGET_BACKUP/"
fi

# 5. Generate Metadata & Checksums
cat << EOF > "$TARGET_BACKUP/metadata.env"
TIMESTAMP=${TS}
APP_VERSION=v1.0.1
BACKUP_TYPE=FULL
OS=$(detect_os)
ARCH=$(detect_architecture)
EOF
chmod 0600 "$TARGET_BACKUP/metadata.env"

# Compute checksums inside backup directory
(cd "$TARGET_BACKUP" && find . -type f ! -name "SHA256SUMS.txt" -exec sha256sum {} + > SHA256SUMS.txt)
chmod 0600 "$TARGET_BACKUP/SHA256SUMS.txt"

# Record pointer to latest backup
echo "$TARGET_BACKUP" > "$BACKUP_PARENT/latest_backup_path"
chmod 0600 "$BACKUP_PARENT/latest_backup_path"

log_ok "Backup created successfully at: $TARGET_BACKUP"
echo "$TARGET_BACKUP"
