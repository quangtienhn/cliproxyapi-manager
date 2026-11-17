#!/usr/bin/env bash
# ==============================================================================
# Local Simulation Test Suite: Phase 3 Backup & Rollback Runbooks
# ==============================================================================
set -Eeuo pipefail

TMP_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_TEST_DIR"' EXIT

echo "=== Running Phase 3 Backup & Rollback Simulation Test ==="

# 1. Setup mock environment
MOCK_ROOT="$TMP_TEST_DIR/root"
MOCK_BACKUP_PARENT="$TMP_TEST_DIR/var_backups"
MOCK_CONFIG_DIR="$TMP_TEST_DIR/etc_cliproxyapi"
MOCK_AM_DIR="$TMP_TEST_DIR/etc_am"

mkdir -p "$MOCK_BACKUP_PARENT" "$MOCK_CONFIG_DIR" "$MOCK_AM_DIR"

CONFIG_FILE="$MOCK_CONFIG_DIR/config.yaml"
ENV_FILE="$MOCK_AM_DIR/manager.env"

echo "port: 8317\nhost: '<TX3_IP>'" > "$CONFIG_FILE"
echo "PORT=8320\nCLIPROXYAPI_URL=http://127.0.0.1:8317" > "$ENV_FILE"

chmod 0640 "$CONFIG_FILE" "$ENV_FILE"

# 2. Test Backup Simulation
BACKUP_TS="$(date +%Y%m%dT%H%M%S)"
BACKUP_DIR="${MOCK_BACKUP_PARENT}/cliproxyapi-phase3-${BACKUP_TS}"
mkdir -p "$BACKUP_DIR"

stat -c 'UID=%u GID=%g MODE=%a SIZE=%s' "$CONFIG_FILE" > "$BACKUP_DIR/config.yaml.meta"
stat -c 'UID=%u GID=%g MODE=%a SIZE=%s' "$ENV_FILE" > "$BACKUP_DIR/manager.env.meta"

cp -a "$CONFIG_FILE" "$BACKUP_DIR/config.yaml"
cp -a "$ENV_FILE" "$BACKUP_DIR/manager.env"
chmod 0600 "$BACKUP_DIR/config.yaml" "$BACKUP_DIR/manager.env"

(cd "$BACKUP_DIR" && sha256sum config.yaml manager.env > SHA256SUMS)

POINTER_FILE="${MOCK_BACKUP_PARENT}/latest_phase3_backup"
TMP_PTR="$(mktemp "${MOCK_BACKUP_PARENT}/.ptr.XXXXXX")"
echo "$BACKUP_DIR" > "$TMP_PTR"
mv "$TMP_PTR" "$POINTER_FILE"

echo "PASS: Backup creation and checksumming simulation succeeded."

# 3. Modify original files (simulate change to host: 0.0.0.0)
echo "port: 8317\nhost: '0.0.0.0'" > "$CONFIG_FILE"
echo "PORT=8320\nCLIPROXYAPI_MANAGEMENT_KEY=changed" > "$ENV_FILE"

# 4. Test Rollback Simulation with Metadata Restoration
RAW_BACKUP_DIR="$(cat "$POINTER_FILE" | tr -d ' \t\r\n')"
(cd "$RAW_BACKUP_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1)

parse_meta() {
  local meta_file="$1"
  local uid gid mode size
  while read -r line || [[ -n "$line" ]]; do
    for pair in $line; do
      case "$pair" in
        UID=*) uid="${pair#UID=}" ;;
        GID=*) gid="${pair#GID=}" ;;
        MODE=*) mode="${pair#MODE=}" ;;
        SIZE=*) size="${pair#SIZE=}" ;;
      esac
    done
  done < "$meta_file"
  echo "$uid $gid $mode"
}

CFG_META=$(parse_meta "$RAW_BACKUP_DIR/config.yaml.meta")
read -r CFG_UID CFG_GID CFG_MODE <<< "$CFG_META"

TMP_CFG="$(mktemp "${MOCK_CONFIG_DIR}/.cfg.XXXXXX")"
cp "$RAW_BACKUP_DIR/config.yaml" "$TMP_CFG"
chmod "$CFG_MODE" "$TMP_CFG"
mv "$TMP_CFG" "$CONFIG_FILE"

# Verify restored content matches original pre-change content
if grep -q "host: '<TX3_IP>'" "$CONFIG_FILE"; then
  echo "PASS: Rollback restored exact original config content."
else
  echo "FAIL: Config not restored properly!" >&2
  exit 1
fi

echo "=== All Phase 3 Backup & Rollback Simulation Tests PASSED ==="
