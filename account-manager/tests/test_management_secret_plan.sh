#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
SECRET_FILE=""
cleanup() {
  [[ -z "$SECRET_FILE" ]] || rm -f -- "$SECRET_FILE"
  rm -rf -- "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/etc" "$WORK/release/src" "$WORK/backups" "$WORK/bin"
cp "$ROOT/src/sync_secret.js" "$WORK/release/src/"
cp "$ROOT/package.json" "$ROOT/package-lock.json" "$WORK/release/"
(cd "$WORK/release" && npm ci --ignore-scripts --omit=dev --no-audit --no-fund >/dev/null)

new_secret() {
  [[ -z "$SECRET_FILE" ]] || rm -f -- "$SECRET_FILE"
  SECRET_FILE="$(mktemp /tmp/cliproxyapi-management-secret.XXXXXX)"
  chmod 600 "$SECRET_FILE"
  if [[ "$1" == newline ]]; then
    printf '%s\n' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' > "$SECRET_FILE"
  else
    printf '%s' "$1" > "$SECRET_FILE"
  fi
}
make_fixture() {
  printf 'port: 8317\nmanagement:\n  allow-remote: false\n  secret-key: ""\nother:\n  keep: "unchanged"\n' > "$WORK/etc/config.yaml"
  printf 'PORT=8320\nCLIPROXYAPI_URL=http://127.0.0.1:8317\n' > "$WORK/etc/manager.env"
  chmod 640 "$WORK/etc/config.yaml" "$WORK/etc/manager.env"
  new_secret newline
}
run_sync() {
  PHASE3_SYNC_APPROVED=1 bash "$ROOT/preparation/sync_management_secret.sh" --apply \
    "$WORK/etc/config.yaml" "$WORK/etc/manager.env" "$WORK/release" "$SECRET_FILE" "$WORK/backups"
}
backup_count() { find "$WORK/backups" -mindepth 1 -maxdepth 1 -type d | wc -l; }

make_fixture
config_before="$(sha256sum "$WORK/etc/config.yaml")"; env_before="$(sha256sum "$WORK/etc/manager.env")"
output="$(run_sync 2>&1)"
[[ "$output" != *0123456789abcdef* ]]
[[ "$(backup_count)" == 1 ]]
[[ ! -e "$SECRET_FILE" ]]                       # temporary secret removed on success
[[ "$(stat -c '%a' "$WORK/etc/config.yaml")" == 640 ]]
[[ "$(stat -c '%a' "$WORK/etc/manager.env")" == 640 ]]
BACKUP_DIR="$(find "$WORK/backups" -mindepth 1 -maxdepth 1 -type d)"
[[ "$(stat -c '%a' "$BACKUP_DIR")" == 700 && "$(stat -c '%u:%g' "$BACKUP_DIR")" == 0:0 ]]
[[ -f "$BACKUP_DIR/SHA256SUMS" && -f "$BACKUP_DIR/config.yaml.meta" && -f "$BACKUP_DIR/manager.env.meta" ]]
node --input-type=module - "$WORK/etc/config.yaml" "$WORK/etc/manager.env" <<'NODE'
import fs from 'node:fs'; import YAML from 'yaml';
const [cfg, env] = process.argv.slice(2); const secret = YAML.parse(fs.readFileSync(cfg,'utf8')).management['secret-key'];
const text = fs.readFileSync(env,'utf8'); if (!text.includes(`CLIPROXYAPI_MANAGEMENT_KEY=${JSON.stringify(secret)}`)) throw new Error('round-trip failed');
if (text.split(/\r?\n/).filter(x => x.startsWith('CLIPROXYAPI_MANAGEMENT_KEY=')).length !== 1) throw new Error('duplicate key');
if (secret.length !== 64 || !/^[0-9a-f]+$/i.test(secret)) throw new Error('secret format failed');
NODE

# A non-empty existing secret must be refused without touching either file.
printf 'port: 8317\nmanagement:\n  allow-remote: false\n  secret-key: "existing-secret"\n' > "$WORK/etc/config.yaml"
config_full="$(sha256sum "$WORK/etc/config.yaml")"; env_full="$(sha256sum "$WORK/etc/manager.env")"
new_secret newline
if run_sync >"$WORK/nonempty.out" 2>&1; then exit 1; fi
[[ "$(sha256sum "$WORK/etc/config.yaml")" == "$config_full" ]]
[[ "$(sha256sum "$WORK/etc/manager.env")" == "$env_full" ]]
[[ "$(backup_count)" == 1 ]]
[[ "$(cat "$WORK/nonempty.out")" != *0123456789abcdef* ]]

# Malformed YAML: preflight refusal keeps both files unchanged.
make_fixture
config_before="$(sha256sum "$WORK/etc/config.yaml")"; env_before="$(sha256sum "$WORK/etc/manager.env")"
printf 'port: 8317\nmanagement: [broken\n' > "$WORK/etc/config.yaml"
config_broken="$(sha256sum "$WORK/etc/config.yaml")"
if run_sync >"$WORK/malformed.out" 2>&1; then exit 1; fi
[[ "$(sha256sum "$WORK/etc/config.yaml")" == "$config_broken" ]]
[[ "$(sha256sum "$WORK/etc/manager.env")" == "$env_before" ]]
[[ "$(cat "$WORK/malformed.out")" != *0123456789abcdef* ]]

# Secret format rejection: empty, short, non-hex, two trailing newlines.
make_fixture
for value in '' 'abc' 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'; do
  new_secret "$value"; ! run_sync >/dev/null 2>&1
done
new_secret newline; printf '\n' >> "$SECRET_FILE"; ! run_sync >/dev/null 2>&1

# Symlink secret and non-0600 secret are rejected.
make_fixture
REAL_SECRET="$(mktemp /tmp/cliproxyapi-management-secret-real.XXXXXX)"
printf '%064d' 0 > "$REAL_SECRET"; chmod 600 "$REAL_SECRET"
rm -f "$SECRET_FILE"; ln -s "$REAL_SECRET" "$SECRET_FILE"; ! run_sync >/dev/null 2>&1
rm -f "$SECRET_FILE" "$REAL_SECRET"
new_secret newline; chmod 644 "$SECRET_FILE"; ! run_sync >/dev/null 2>&1

# Explicit rollback: restore both files from the retained backup.
make_fixture; run_sync >/dev/null
BACKUP_DIR="$(find "$WORK/backups" -mindepth 1 -maxdepth 1 -type d | tail -n 1)"
printf 'changed\n' > "$WORK/etc/config.yaml"; printf 'changed\n' > "$WORK/etc/manager.env"
PHASE3_SYNC_APPROVED=1 bash "$ROOT/preparation/rollback_management_secret.sh" --restore \
  "$BACKUP_DIR" "$WORK/etc/config.yaml" "$WORK/etc/manager.env" "$WORK/backups" >/dev/null
[[ "$(sha256sum "$WORK/etc/config.yaml")" == "$(sha256sum "$BACKUP_DIR/config.yaml")" ]]
[[ "$(sha256sum "$WORK/etc/manager.env")" == "$(sha256sum "$BACKUP_DIR/manager.env")" ]]
[[ "$(stat -c '%a' "$WORK/etc/config.yaml")" == 640 ]]

# A backup outside the prescribed root is rejected.
OUTSIDE="$(mktemp -d)"; cp -a "$BACKUP_DIR/." "$OUTSIDE/"
if PHASE3_SYNC_APPROVED=1 bash "$ROOT/preparation/rollback_management_secret.sh" --restore \
  "$OUTSIDE" "$WORK/etc/config.yaml" "$WORK/etc/manager.env" "$WORK/backups" >/dev/null 2>&1; then
  exit 1
fi
rm -rf -- "$OUTSIDE"

# INT/TERM during mutation retains the backup, restores both files, removes the
# temporary secret and never prints it.
make_fixture
config_before="$(sha256sum "$WORK/etc/config.yaml")"; env_before="$(sha256sum "$WORK/etc/manager.env")"
cat > "$WORK/bin/node" <<'NODE_SH'
#!/usr/bin/env bash
if [[ "$#" -ge 5 ]]; then sleep 30; else exit 0; fi
NODE_SH
chmod 755 "$WORK/bin/node"
set +e
PATH="$WORK/bin:$PATH" PHASE3_SYNC_APPROVED=1 bash "$ROOT/preparation/sync_management_secret.sh" --apply \
  "$WORK/etc/config.yaml" "$WORK/etc/manager.env" "$WORK/release" "$SECRET_FILE" "$WORK/backups" >"$WORK/signal.out" 2>&1 &
pid=$!; sleep 1; kill -TERM "$pid"; wait "$pid"; signal_rc=$?
set -e
[[ "$signal_rc" == 143 ]]
[[ -f "$BACKUP_DIR/SHA256SUMS" ]]
[[ ! -e "$SECRET_FILE" ]]
[[ "$(sha256sum "$WORK/etc/config.yaml")" == "$config_before" ]]
[[ "$(sha256sum "$WORK/etc/manager.env")" == "$env_before" ]]
[[ "$(cat "$WORK/signal.out")" != *0123456789abcdef* ]]

echo '[PASS] management secret preparation: empty-only sync, retention, validation, rollback, containment, signal and leak checks'
