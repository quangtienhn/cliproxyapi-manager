#!/usr/bin/env bash
# ==============================================================================
# Phase 3 Hardened Backup Script (TX3 Debian 12 ARM64)
# ==============================================================================
# Usage:
#   sudo ./backup_phase3.sh
# ==============================================================================

set -Eeuo pipefail

# 1. Root Privilege Enforcement
if [[ "$(id -u)" -ne 0 && "${PHASE3_TEST_MODE:-0}" != "1" ]]; then
  echo "[ERROR] Backup script must be executed as root (or with sudo)." >&2
  exit 1
fi

# 2. Command Pre-flight Verification
REQUIRED_COMMANDS=(mkdir cp stat chmod chown sha256sum date realpath mktemp mv basename dirname)
for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required system utility '$cmd' not found!" >&2
    exit 1
  fi
done

# 3. Source Files Pre-flight Verification
SRC_CONFIG="${PHASE3_SOURCE_CONFIG:-/etc/cliproxyapi/config.yaml}"
SRC_ENV="${PHASE3_SOURCE_ENV:-/etc/cliproxyapi-account-manager/manager.env}"

for f in "$SRC_CONFIG" "$SRC_ENV"; do
  if [[ ! -e "$f" ]]; then
    echo "[ERROR] Source file does not exist: $f" >&2
    exit 1
  fi
  if [[ -L "$f" ]]; then
    echo "[ERROR] Security violation: Source file is an unexpected symlink: $f" >&2
    exit 1
  fi
  if [[ ! -f "$f" ]]; then
    echo "[ERROR] Source is not a regular file: $f" >&2
    exit 1
  fi
  if [[ ! -s "$f" ]]; then
    echo "[ERROR] Source file is unexpectedly empty: $f" >&2
    exit 1
  fi
done

# 4. Create Timestamped Direct Child Directory under /var/backups with Collision Protection
BACKUP_PARENT="${PHASE3_BACKUP_PARENT:-/var/backups}"
BACKUP_TS="$(date +%Y%m%dT%H%M%S)"
BACKUP_DIR="${BACKUP_PARENT}/cliproxyapi-phase3-${BACKUP_TS}"
COUNTER=1

while [[ -e "$BACKUP_DIR" ]]; do
  BACKUP_DIR="${BACKUP_PARENT}/cliproxyapi-phase3-${BACKUP_TS}_${COUNTER}"
  COUNTER=$((COUNTER + 1))
done

mkdir -p "$BACKUP_DIR"
if [[ "${PHASE3_TEST_MODE:-0}" != "1" ]]; then chown root:root "$BACKUP_DIR"; fi
chmod 0700 "$BACKUP_DIR"

# 5. Capture Original File Metadata into Machine-Readable Format
stat -c 'UID=%u GID=%g MODE=%a SIZE=%s' "$SRC_CONFIG" > "$BACKUP_DIR/config.yaml.meta"
stat -c 'UID=%u GID=%g MODE=%a SIZE=%s' "$SRC_ENV" > "$BACKUP_DIR/manager.env.meta"
chmod 0600 "$BACKUP_DIR/config.yaml.meta" "$BACKUP_DIR/manager.env.meta"

# Strict verification of metadata file format before proceeding
validate_meta_format() {
  local mf="$1"
  local line
  line=$(cat "$mf" | tr -d '\r\n')
  if [[ ! "$line" =~ ^UID=[0-9]+[[:space:]]GID=[0-9]+[[:space:]]MODE=[0-7]{3,4}[[:space:]]SIZE=[0-9]+$ ]]; then
    echo "[ERROR] Invalid metadata format in $mf: '$line'" >&2
    return 1
  fi
  return 0
}

validate_meta_format "$BACKUP_DIR/config.yaml.meta" || exit 1
validate_meta_format "$BACKUP_DIR/manager.env.meta" || exit 1

# 6. Copy Source Files and Enforce Restrictive Permissions (0600)
cp -a "$SRC_CONFIG" "$BACKUP_DIR/config.yaml"
cp -a "$SRC_ENV" "$BACKUP_DIR/manager.env"
chmod 0600 "$BACKUP_DIR/config.yaml" "$BACKUP_DIR/manager.env"

# Verify actual sizes match recorded metadata sizes
CFG_REC_SIZE=$(grep -oE 'SIZE=[0-9]+' "$BACKUP_DIR/config.yaml.meta" | cut -d'=' -f2)
ENV_REC_SIZE=$(grep -oE 'SIZE=[0-9]+' "$BACKUP_DIR/manager.env.meta" | cut -d'=' -f2)

CFG_ACT_SIZE=$(stat -c '%s' "$BACKUP_DIR/config.yaml")
ENV_ACT_SIZE=$(stat -c '%s' "$BACKUP_DIR/manager.env")

if [[ "$CFG_REC_SIZE" != "$CFG_ACT_SIZE" ]] || [[ "$ENV_REC_SIZE" != "$ENV_ACT_SIZE" ]]; then
  echo "[ERROR] Size mismatch between recorded metadata and copied files!" >&2
  exit 1
fi

# 7. Generate and Verify SHA256 Checksums covering BOTH config files and BOTH metadata files
(cd "$BACKUP_DIR" && sha256sum config.yaml manager.env config.yaml.meta manager.env.meta > SHA256SUMS)
chmod 0600 "$BACKUP_DIR/SHA256SUMS"

# Strict verification of backup contents
(cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || {
  echo "[ERROR] Checksum verification failed immediately after backup creation!" >&2
  exit 1
}

# 8. Atomic Pointer File Creation / Update
POINTER_FILE="${PHASE3_POINTER_FILE:-${BACKUP_PARENT}/latest_phase3_backup}"
TMP_POINTER="$(mktemp "${BACKUP_PARENT}/.phase3_ptr.XXXXXX")"

echo "$BACKUP_DIR" > "$TMP_POINTER"
if [[ "${PHASE3_TEST_MODE:-0}" != "1" ]]; then chown root:root "$TMP_POINTER"; fi
chmod 0600 "$TMP_POINTER"

mv "$TMP_POINTER" "$POINTER_FILE"

echo "[SUCCESS] Verified complete backup created at: $BACKUP_DIR"
echo "[SUCCESS] Pointer updated atomically: $POINTER_FILE -> $BACKUP_DIR"
