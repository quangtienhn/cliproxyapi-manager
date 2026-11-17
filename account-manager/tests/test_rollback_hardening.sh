#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
BACKUPS="$TMP_DIR/backups"
SOURCE="$TMP_DIR/source"
TARGET="$TMP_DIR/target"
mkdir -p "$BACKUPS" "$SOURCE" "$TARGET/config" "$TARGET/env"
printf 'port: 8317\nmanagement:\n  allow-remote: false\n' > "$SOURCE/config.yaml"
printf 'PORT=8320\nCLIPROXYAPI_URL=http://127.0.0.1:8317\n' > "$SOURCE/manager.env"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\ncase "$1 $2" in *"is-active"*) echo active;; esac\n' "$TMP_DIR/systemctl.log" > "$TMP_DIR/systemctl"
chmod +x "$TMP_DIR/systemctl"

run_backup() {
  PHASE3_TEST_MODE=1 PHASE3_SOURCE_CONFIG="$SOURCE/config.yaml" PHASE3_SOURCE_ENV="$SOURCE/manager.env" \
  PHASE3_BACKUP_PARENT="$BACKUPS" PHASE3_POINTER_FILE="$BACKUPS/latest_phase3_backup" \
  bash "$ROOT_DIR/deploy/backup_phase3.sh" >/dev/null
  chmod 600 "$BACKUPS/latest_phase3_backup"
}
run_rollback() {
  PHASE3_TEST_MODE=1 PHASE3_BACKUP_PARENT="$BACKUPS" PHASE3_POINTER_FILE="$BACKUPS/latest_phase3_backup" \
  PHASE3_TARGET_CONFIG="$TARGET/config/config.yaml" PHASE3_TARGET_ENV="$TARGET/env/manager.env" \
  PHASE3_SYSTEMCTL_BIN="$TMP_DIR/systemctl" PHASE3_NODE_BIN="node" \
  bash "$ROOT_DIR/deploy/rollback_phase3.sh" >/dev/null
}

echo '[1] actual backup and rollback'
run_backup
run_rollback
test -f "$TARGET/config/config.yaml" && test -f "$TARGET/env/manager.env"
BACKUP_DIR="$(cat "$BACKUPS/latest_phase3_backup")"
CFG_MODE="$(sed -n 's/.*MODE=\([0-7]*\).*/\1/p' "$BACKUP_DIR/config.yaml.meta")"
ENV_MODE="$(sed -n 's/.*MODE=\([0-7]*\).*/\1/p' "$BACKUP_DIR/manager.env.meta")"
[[ "$(stat -c '%a' "$TARGET/config/config.yaml")" == "$CFG_MODE" ]]
[[ "$(stat -c '%a' "$TARGET/env/manager.env")" == "$ENV_MODE" ]]

echo '[2] invalid pointer and nested path rejection'
printf '\nextra\n' > "$BACKUPS/latest_phase3_backup"
if run_rollback 2>/dev/null; then exit 1; fi
chmod 600 "$BACKUPS/latest_phase3_backup"
printf '%s/nested/cliproxyapi-phase3-20261110T000000\n' "$BACKUPS" > "$BACKUPS/latest_phase3_backup"
if run_rollback 2>/dev/null; then exit 1; fi

echo '[3] malformed YAML containing port must not restart'
printf 'port: 8317\nmanagement: [broken\n' > "$SOURCE/config.yaml"
run_backup
BACKUP_DIR="$(cat "$BACKUPS/latest_phase3_backup")"
printf 'port: 8317\nmanagement: [broken\n' > "$BACKUP_DIR/config.yaml"
stat -c 'UID=%u GID=%g MODE=%a SIZE=%s' "$BACKUP_DIR/config.yaml" > "$BACKUP_DIR/config.yaml.meta"
(cd "$BACKUP_DIR" && sha256sum config.yaml manager.env config.yaml.meta manager.env.meta > SHA256SUMS)
: > "$TMP_DIR/systemctl.log"
if run_rollback 2>/dev/null; then exit 1; fi
test ! -s "$TMP_DIR/systemctl.log"

echo '[4] failed checksum'
run_backup
BACKUP_DIR="$(cat "$BACKUPS/latest_phase3_backup")"
printf 'tampered\n' >> "$BACKUP_DIR/manager.env"
if run_rollback 2>/dev/null; then exit 1; fi

echo '[5] second replacement failure restores both files to pre-rollback state'
printf 'port: 8317\nmanagement:\n  allow-remote: false\n' > "$SOURCE/config.yaml"
run_backup
printf 'live-config\n' > "$TARGET/config/config.yaml"
printf 'live-env\n' > "$TARGET/env/manager.env"
REAL_MV="$(command -v mv)"
mkdir -p "$TMP_DIR/failbin"
cat > "$TMP_DIR/failbin/mv" <<EOF
#!/usr/bin/env bash
last="\${!#}"
if [[ "\$last" == */manager.env && ! -e "$TMP_DIR/fail-once" ]]; then
  : > "$TMP_DIR/fail-once"
  echo 'forced second-rename failure' >&2
  exit 1
fi
exec "$REAL_MV" "\$@"
EOF
chmod +x "$TMP_DIR/failbin/mv"
: > "$TMP_DIR/systemctl.log"
if PATH="$TMP_DIR/failbin:$PATH" run_rollback 2>"$TMP_DIR/restore.err"; then exit 1; fi
grep -q 'pre-rollback state' "$TMP_DIR/restore.err"
[[ "$(cat "$TARGET/config/config.yaml")" == 'live-config' ]]
[[ "$(cat "$TARGET/env/manager.env")" == 'live-env' ]]
test ! -s "$TMP_DIR/systemctl.log"

echo '[6] sync helper delegates restore to the verified rollback helper'
SYNC_HELPER="$ROOT_DIR/preparation/sync_management_secret.sh"
ROLLBACK_HELPER="$ROOT_DIR/preparation/rollback_management_secret.sh"
grep -q 'rollback_management_secret.sh' "$SYNC_HELPER"
grep -q 'verify_backup ||' "$SYNC_HELPER"
grep -q -- '--restore' "$SYNC_HELPER"
grep -q 'CRITICAL' "$SYNC_HELPER"
if grep -q 'systemctl' "$SYNC_HELPER"; then exit 1; fi
bash -n "$SYNC_HELPER" "$ROLLBACK_HELPER"

echo 'All actual backup/rollback integration tests passed.'
