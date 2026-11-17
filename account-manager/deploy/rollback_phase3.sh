#!/usr/bin/env bash
# ==============================================================================
# Phase 3 Hardened Rollback Script (TX3 Debian 12 ARM64)
# ==============================================================================
# Usage:
#   sudo ./rollback_phase3.sh
# ==============================================================================

set -Eeuo pipefail

# 1. Root Privilege Enforcement
if [[ "$(id -u)" -ne 0 && "${PHASE3_TEST_MODE:-0}" != "1" ]]; then
  echo "[ERROR] Rollback script must be executed as root (or with sudo)." >&2
  exit 1
fi

BACKUP_PARENT="${PHASE3_BACKUP_PARENT:-/var/backups}"
POINTER_FILE="${PHASE3_POINTER_FILE:-${BACKUP_PARENT}/latest_phase3_backup}"
TARGET_CONFIG="${PHASE3_TARGET_CONFIG:-/etc/cliproxyapi/config.yaml}"
TARGET_ENV="${PHASE3_TARGET_ENV:-/etc/cliproxyapi-account-manager/manager.env}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
NODE_BIN="${PHASE3_NODE_BIN:-node}"
SYSTEMCTL_BIN="${PHASE3_SYSTEMCTL_BIN:-systemctl}"
EXPECTED_OWNER="0:0"
if [[ "${PHASE3_TEST_MODE:-0}" == "1" ]]; then EXPECTED_OWNER="$(id -u):$(id -g)"; fi

reject_symlink_components() {
  local path="$1"
  local current="/"
  local component
  local -a components
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -z "$component" || "$component" == "." ]] && continue
    current="${current%/}/$component"
    if [[ -L "$current" ]]; then
      echo "[ERROR] [Stage: Path Containment] Security violation: symlinked path component: $current" >&2
      return 1
    fi
  done
}

if [[ "$BACKUP_PARENT" != /* ]]; then
  echo "[ERROR] [Stage: Path Containment] Backup parent must be an absolute path" >&2
  exit 1
fi
reject_symlink_components "$BACKUP_PARENT" || exit 1

echo "=== CLIProxyAPI Phase 3 Rollback Routine ==="

# 2. Pointer File Validation
echo "[1/6] Validating pointer file..."
if [[ ! -e "$POINTER_FILE" ]]; then
  echo "[ERROR] [Stage: Pointer Validation] Pointer file does not exist: $POINTER_FILE" >&2
  exit 1
fi
if [[ -L "$POINTER_FILE" ]]; then
  echo "[ERROR] [Stage: Pointer Validation] Security violation: Pointer file is an unexpected symlink: $POINTER_FILE" >&2
  exit 1
fi
if [[ ! -f "$POINTER_FILE" ]]; then
  echo "[ERROR] [Stage: Pointer Validation] Pointer is not a regular file: $POINTER_FILE" >&2
  exit 1
fi

PTR_OWNER=$(stat -c '%u:%g' "$POINTER_FILE" 2>/dev/null || echo "0:0")
if [[ "$PTR_OWNER" != "$EXPECTED_OWNER" ]]; then
  echo "[ERROR] [Stage: Pointer Validation] Pointer file is not owned by root:root ($PTR_OWNER)!" >&2
  exit 1
fi

PTR_MODE=$(stat -c '%a' "$POINTER_FILE" 2>/dev/null || echo "600")
if [[ "$PTR_MODE" != "600" && "${PHASE3_TEST_MODE:-0}" != "1" ]]; then
  echo "[ERROR] [Stage: Pointer Validation] Pointer file mode is $PTR_MODE; exactly 0600 is required" >&2
  exit 1
fi

if [[ "$(wc -l < "$POINTER_FILE")" -ne 1 ]]; then
  echo "[ERROR] [Stage: Pointer Validation] Pointer must contain exactly one path line" >&2
  exit 1
fi
RAW_BACKUP_DIR="$(sed 's/\r$//' "$POINTER_FILE")"
if [[ -z "$RAW_BACKUP_DIR" || "$RAW_BACKUP_DIR" =~ [[:space:]] ]]; then
  echo "[ERROR] [Stage: Pointer Validation] Pointer file is empty!" >&2
  exit 1
fi

# 3. Canonicalize and Enforce Strict Direct-Child Directory Containment
echo "[2/6] Validating backup directory containment..."

if [[ "$RAW_BACKUP_DIR" != /* ]]; then
  echo "[ERROR] [Stage: Path Containment] Pointer path must be absolute" >&2
  exit 1
fi

# Validate the original path before any canonicalization. The pointer must name
# exactly one direct child of the configured parent, with no symlink aliases.
if [[ "$(dirname "$RAW_BACKUP_DIR")" != "$BACKUP_PARENT" ]] ||
   [[ ! "$(basename "$RAW_BACKUP_DIR")" =~ ^cliproxyapi-phase3-[0-9]{8}T[0-9]{6}(_[0-9]+)?$ ]]; then
  echo "[ERROR] [Stage: Path Containment] Pointer path is not an authorized direct child" >&2
  exit 1
fi
if [[ -L "$RAW_BACKUP_DIR" ]]; then
  echo "[ERROR] [Stage: Path Containment] Security violation: backup directory path is a symlink" >&2
  exit 1
fi

REAL_PARENT="$(realpath -e -- "$BACKUP_PARENT")"
REAL_BACKUP_DIR="$(realpath -e -- "$RAW_BACKUP_DIR")"

# A non-symlink, direct-child raw path should canonicalize identically. Reject
# any unexpected change rather than silently accepting an alias.
if [[ "$REAL_BACKUP_DIR" != "$RAW_BACKUP_DIR" ]]; then
  echo "[ERROR] [Stage: Path Containment] Backup path changed during canonicalization" >&2
  exit 1
fi

if [[ ! -d "$REAL_BACKUP_DIR" ]]; then
  echo "[ERROR] [Stage: Path Containment] Backup directory does not exist: $REAL_BACKUP_DIR" >&2
  exit 1
fi
if [[ -L "$REAL_BACKUP_DIR" ]]; then
  echo "[ERROR] [Stage: Path Containment] Security violation: Backup directory is a symlink: $REAL_BACKUP_DIR" >&2
  exit 1
fi

# Ensure direct child (dirname must equal REAL_PARENT, and basename must start with cliproxyapi-phase3-)
DIR_PARENT="$(dirname "$REAL_BACKUP_DIR")"
DIR_BASE="$(basename "$REAL_BACKUP_DIR")"

if [[ "$DIR_PARENT" != "$REAL_PARENT" ]] || [[ ! "$DIR_BASE" =~ ^cliproxyapi-phase3-[0-9]{8}T[0-9]{6}(_[0-9]+)?$ ]]; then
  echo "[ERROR] [Stage: Path Containment] Security violation: Backup directory is not a direct authorized child: $REAL_BACKUP_DIR" >&2
  exit 1
fi

# Scan for symlinks inside the backup directory
if find "$REAL_BACKUP_DIR" -type l 2>/dev/null | grep -q .; then
  echo "[ERROR] [Stage: Path Containment] Security violation: Backup directory contains symbolic links!" >&2
  exit 1
fi

DIR_OWNER=$(stat -c '%u:%g' "$REAL_BACKUP_DIR" 2>/dev/null || echo "0:0")
if [[ "$DIR_OWNER" != "$EXPECTED_OWNER" ]]; then
  echo "[ERROR] [Stage: Path Containment] Backup directory is not owned by root:root ($DIR_OWNER)!" >&2
  exit 1
fi

# 4. Checksum and Integrity Verification
echo "[3/6] Verifying backup checksum integrity..."
REQUIRED_ITEMS=("$REAL_BACKUP_DIR/config.yaml" "$REAL_BACKUP_DIR/manager.env" "$REAL_BACKUP_DIR/config.yaml.meta" "$REAL_BACKUP_DIR/manager.env.meta" "$REAL_BACKUP_DIR/SHA256SUMS")
for item in "${REQUIRED_ITEMS[@]}"; do
  if [[ -L "$item" || ! -f "$item" ]]; then
    echo "[ERROR] [Stage: Checksum Verification] Missing backup component: $item" >&2
    exit 1
  fi
done

(cd "$REAL_BACKUP_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || {
  echo "[ERROR] [Stage: Checksum Verification] Backup integrity failure: SHA256SUMS do not match!" >&2
  exit 1
}

# 5. Metadata Parser & Size Validation
echo "[4/6] Parsing metadata and validating sizes..."

parse_and_validate_meta() {
  local meta_file="$1"
  local target_file="$2"
  local line
  if [[ "$(wc -l < "$meta_file")" -ne 1 ]]; then return 1; fi
  line=$(sed 's/\r$//' "$meta_file")

  if [[ ! "$line" =~ ^UID=([0-9]+)[[:space:]]GID=([0-9]+)[[:space:]]MODE=([0-7]{3,4})[[:space:]]SIZE=([0-9]+)$ ]]; then
    echo "[ERROR] [Stage: Metadata Validation] Malformed metadata line in $meta_file" >&2
    return 1
  fi

  local uid="${BASH_REMATCH[1]}"
  local gid="${BASH_REMATCH[2]}"
  local mode="${BASH_REMATCH[3]}"
  local size="${BASH_REMATCH[4]}"
  if (( 10#$uid > 4294967295 || 10#$gid > 4294967295 || 8#$mode > 0777 )); then return 1; fi

  # Verify recorded size matches actual file size
  local act_size
  act_size=$(stat -c '%s' "$target_file")
  if [[ "$size" != "$act_size" ]]; then
    echo "[ERROR] [Stage: Metadata Validation] File size mismatch for $target_file: expected $size, actual $act_size" >&2
    return 1
  fi

  echo "$uid $gid $mode $size"
  return 0
}

CFG_META=$(parse_and_validate_meta "$REAL_BACKUP_DIR/config.yaml.meta" "$REAL_BACKUP_DIR/config.yaml") || exit 1
ENV_META=$(parse_and_validate_meta "$REAL_BACKUP_DIR/manager.env.meta" "$REAL_BACKUP_DIR/manager.env") || exit 1

read -r CFG_UID CFG_GID CFG_MODE CFG_SIZE <<< "$CFG_META"
read -r ENV_UID ENV_GID ENV_MODE ENV_SIZE <<< "$ENV_META"

# Validate YAML syntax of backup before moving to live system
echo "[INFO] Validating YAML syntax of restored configuration..."
"$NODE_BIN" "$SCRIPT_DIR/../src/validate_yaml.js" "$REAL_BACKUP_DIR/config.yaml" >/dev/null || {
  echo "[ERROR] [Stage: YAML Validation] Restored config.yaml failed structural validation!" >&2
  exit 1
}

# Validate manager.env structure without printing secrets
node -e "
const fs = require('fs');
const content = fs.readFileSync(process.argv[1], 'utf8');
const lines = content.split('\n');
const keys = new Set();
for (let line of lines) {
  line = line.trim();
  if (!line || line.startsWith('#')) continue;
  if (!/^[A-Za-z_][A-Za-z0-9_]*=.*$/.test(line)) throw new Error('Malformed environment line');
  const k = line.split('=')[0];
  if (keys.has(k)) throw new Error('Duplicate key: ' + k);
  keys.add(k);
}
if (!keys.has('PORT') || !keys.has('CLIPROXYAPI_URL')) throw new Error('Missing required env keys');
" "$REAL_BACKUP_DIR/manager.env" || {
  echo "[ERROR] [Stage: Env Validation] Restored manager.env failed structural validation!" >&2
  exit 1
}

# Atomic restore of config.yaml and manager.env as one coordinated pair.
if [[ ! -d "$(dirname "$TARGET_CONFIG")" || ! -d "$(dirname "$TARGET_ENV")" ]]; then
  echo "[ERROR] [Stage: Restore Preparation] Target directories do not exist" >&2
  exit 1
fi
for target in "$TARGET_CONFIG" "$TARGET_ENV"; do
  if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
    echo "[ERROR] [Stage: Restore Preparation] Target is not a regular non-symlink file: $target" >&2
    exit 1
  fi
done

TMP_CFG=""; TMP_ENV=""; PRE_CFG=""; PRE_ENV=""; RESTORE_STARTED=0
cleanup_restore_temps() {
  [[ -z "$TMP_CFG" ]] || rm -f -- "$TMP_CFG"
  [[ -z "$TMP_ENV" ]] || rm -f -- "$TMP_ENV"
  [[ -z "$PRE_CFG" ]] || rm -f -- "$PRE_CFG"
  [[ -z "$PRE_ENV" ]] || rm -f -- "$PRE_ENV"
}
restore_pre_rollback() {
  local rc=0
  if [[ -n "$PRE_CFG" && -f "$PRE_CFG" ]]; then mv -f -- "$PRE_CFG" "$TARGET_CONFIG" || rc=1; else rc=1; fi
  if [[ -n "$PRE_ENV" && -f "$PRE_ENV" ]]; then mv -f -- "$PRE_ENV" "$TARGET_ENV" || rc=1; else rc=1; fi
  TMP_CFG=""; TMP_ENV=""; PRE_CFG=""; PRE_ENV=""
  return "$rc"
}
handle_restore_error() {
  local code=$?
  trap - ERR INT TERM
  if [[ "$RESTORE_STARTED" != 1 ]]; then
    cleanup_restore_temps
    exit "$code"
  fi
  echo "[ERROR] [Stage: Restore] Two-file replacement failed after a partial mutation." >&2
  if restore_pre_rollback; then
    echo "[WARN] [Stage: Restore] Both live files were returned to their pre-rollback state." >&2
  else
    echo "[CRITICAL] [Stage: Restore] Could not restore both live files. DO NOT restart services." >&2
  fi
  echo "[WARN] [Stage: Restore] Verified backup retained at: $REAL_BACKUP_DIR" >&2
  exit "$code"
}
handle_restore_signal() {
  trap - ERR INT TERM
  echo "[ERROR] [Stage: Restore] Interrupted during file replacement." >&2
  if [[ "$RESTORE_STARTED" == 1 ]]; then
    if restore_pre_rollback; then
      echo "[WARN] [Stage: Restore] Both live files were returned to their pre-rollback state." >&2
    else
      echo "[CRITICAL] [Stage: Restore] Could not restore both live files. DO NOT restart services." >&2
    fi
  fi
  echo "[WARN] [Stage: Restore] Verified backup retained at: $REAL_BACKUP_DIR" >&2
  exit "$1"
}
trap cleanup_restore_temps EXIT
trap handle_restore_error ERR
trap 'handle_restore_signal 130' INT
trap 'handle_restore_signal 143' TERM

# Stage both replacements completely before touching either live file.
TMP_CFG="$(mktemp "$(dirname "$TARGET_CONFIG")/.cfg.XXXXXX")"
cp "$REAL_BACKUP_DIR/config.yaml" "$TMP_CFG"
chown "${CFG_UID}:${CFG_GID}" "$TMP_CFG"
chmod "$CFG_MODE" "$TMP_CFG"
TMP_ENV="$(mktemp "$(dirname "$TARGET_ENV")/.env.XXXXXX")"
cp "$REAL_BACKUP_DIR/manager.env" "$TMP_ENV"
chown "${ENV_UID}:${ENV_GID}" "$TMP_ENV"
chmod "$ENV_MODE" "$TMP_ENV"
[[ "$(sha256sum -- "$TMP_CFG" | awk '{print $1}')" == "$(sha256sum -- "$REAL_BACKUP_DIR/config.yaml" | awk '{print $1}')" ]] || {
  echo "[ERROR] [Stage: Restore Preparation] Staged config checksum mismatch" >&2
  exit 1
}
[[ "$(sha256sum -- "$TMP_ENV" | awk '{print $1}')" == "$(sha256sum -- "$REAL_BACKUP_DIR/manager.env" | awk '{print $1}')" ]] || {
  echo "[ERROR] [Stage: Restore Preparation] Staged env checksum mismatch" >&2
  exit 1
}

# Snapshot the current live pair so a failure between the two renames can return
# both files to a consistent pre-rollback state instead of leaving them mixed.
if [[ -e "$TARGET_CONFIG" ]]; then
  PRE_CFG="$(mktemp "$(dirname "$TARGET_CONFIG")/.cfg.pre-rollback.XXXXXX")"
  cp -a -- "$TARGET_CONFIG" "$PRE_CFG"
  [[ "$(sha256sum -- "$PRE_CFG" | awk '{print $1}')" == "$(sha256sum -- "$TARGET_CONFIG" | awk '{print $1}')" ]] || {
    echo "[ERROR] [Stage: Restore Preparation] Pre-rollback config snapshot mismatch" >&2
    exit 1
  }
fi
if [[ -e "$TARGET_ENV" ]]; then
  PRE_ENV="$(mktemp "$(dirname "$TARGET_ENV")/.env.pre-rollback.XXXXXX")"
  cp -a -- "$TARGET_ENV" "$PRE_ENV"
  [[ "$(sha256sum -- "$PRE_ENV" | awk '{print $1}')" == "$(sha256sum -- "$TARGET_ENV" | awk '{print $1}')" ]] || {
    echo "[ERROR] [Stage: Restore Preparation] Pre-rollback env snapshot mismatch" >&2
    exit 1
  }
fi

RESTORE_STARTED=1
mv "$TMP_CFG" "$TARGET_CONFIG"; TMP_CFG=""
mv "$TMP_ENV" "$TARGET_ENV"; TMP_ENV=""

[[ "$(stat -c '%u:%g:%a:%s' "$TARGET_CONFIG")" == "$CFG_UID:$CFG_GID:$CFG_MODE:$CFG_SIZE" ]] || {
  echo "[ERROR] [Stage: Restore] Restored config metadata mismatch" >&2
  false
}
[[ "$(stat -c '%u:%g:%a:%s' "$TARGET_ENV")" == "$ENV_UID:$ENV_GID:$ENV_MODE:$ENV_SIZE" ]] || {
  echo "[ERROR] [Stage: Restore] Restored env metadata mismatch" >&2
  false
}
[[ "$(sha256sum -- "$TARGET_CONFIG" | awk '{print $1}')" == "$(sha256sum -- "$REAL_BACKUP_DIR/config.yaml" | awk '{print $1}')" ]] || {
  echo "[ERROR] [Stage: Restore] Restored config checksum mismatch" >&2
  false
}
[[ "$(sha256sum -- "$TARGET_ENV" | awk '{print $1}')" == "$(sha256sum -- "$REAL_BACKUP_DIR/manager.env" | awk '{print $1}')" ]] || {
  echo "[ERROR] [Stage: Restore] Restored env checksum mismatch" >&2
  false
}

RESTORE_STARTED=0
trap - ERR INT TERM
rm -f -- "$PRE_CFG" "$PRE_ENV"; PRE_CFG=""; PRE_ENV=""
cleanup_restore_temps
echo "[OK] Restored configuration and environment files as a verified pair with original permissions."

# 6. Sequential Service Restart and Status Verification
echo "[5/6] Sequentially restarting services..."
"$SYSTEMCTL_BIN" restart cliproxyapi
"$SYSTEMCTL_BIN" restart cliproxyapi-account-manager

echo "[6/6] Verifying service health post-rollback..."
sleep 2

STATUS_CPA=$("$SYSTEMCTL_BIN" is-active cliproxyapi 2>/dev/null || echo "inactive")
STATUS_AM=$("$SYSTEMCTL_BIN" is-active cliproxyapi-account-manager 2>/dev/null || echo "inactive")

if [[ "$STATUS_CPA" != "active" ]]; then
  echo "[ERROR] [Stage: Post-Rollback Health] cliproxyapi service is $STATUS_CPA! Inspect journalctl -u cliproxyapi" >&2
  exit 1
fi

if [[ "$STATUS_AM" != "active" ]]; then
  echo "[ERROR] [Stage: Post-Rollback Health] cliproxyapi-account-manager service is $STATUS_AM! Inspect journalctl -u cliproxyapi-account-manager" >&2
  exit 1
fi

echo "=================================================================="
echo "[SUCCESS] Rollback completed successfully."
echo "Restored from: $REAL_BACKUP_DIR"
echo "cliproxyapi:                 $STATUS_CPA"
echo "cliproxyapi-account-manager: $STATUS_AM"
echo "Backup files safely retained at: $REAL_BACKUP_DIR"
echo "=================================================================="
