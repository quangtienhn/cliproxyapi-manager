#!/usr/bin/env bash
# ==============================================================================
# Update rollback regression test (health check failure restores v1.0.0 files)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/update_rollback_XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

export INSTALLER_TEST_MODE=1
export TEST_FORCE_HEALTH_FAIL=1
export DEFAULT_APP_DIR="$TEST_ROOT/opt/cliproxyapi-account-manager"
export DEFAULT_CONFIG_DIR="$TEST_ROOT/etc/cliproxyapi-account-manager"
export DEFAULT_LOG_DIR="$TEST_ROOT/var/log/cliproxyapi-account-manager"
export DEFAULT_DATA_DIR="$TEST_ROOT/var/lib/cliproxyapi-account-manager"
export DEFAULT_BACKUP_ROOT="$TEST_ROOT/var/backups/cliproxyapi-account-manager"
export DEFAULT_CLIPROXY_CONFIG="$TEST_ROOT/etc/cliproxyapi/config.yaml"
export DEFAULT_AUTH_DIR="$TEST_ROOT/var/lib/cliproxyapi/auths"
export BACKUP_DIR="$DEFAULT_BACKUP_ROOT"
export USER_AUTH_FILE="$TEST_ROOT/home/amtunnel/.ssh/authorized_keys"

mkdir -p "$DEFAULT_APP_DIR/src" "$DEFAULT_CONFIG_DIR" "$DEFAULT_BACKUP_ROOT" "$(dirname "$USER_AUTH_FILE")"
printf 'OLD_VERSION_MARKER\n' > "$DEFAULT_APP_DIR/old-marker.txt"
printf '{"name":"cliproxyapi-account-manager","version":"1.0.0"}\n' > "$DEFAULT_APP_DIR/package.json"
printf 'PORT=8320\nHOST=127.0.0.1\n' > "$DEFAULT_CONFIG_DIR/manager.env"
printf 'command="/bin/false",no-agent-forwarding,no-port-forwarding,permitopen="127.0.0.1:8320" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITunnelKey amtunnel@haos\n' > "$USER_AUTH_FILE"

echo "=== Update rollback on unhealthy service ==="
set +e
bash "$PROJECT_ROOT/server-installer/update.sh" > "$TEST_ROOT/update.log" 2>&1
RC=$?
set -e

[[ "$RC" -ne 0 ]] && ok "failed health check makes update exit non-zero" || bad "update reported success despite forced failure"
grep -q 'Rolling back' "$TEST_ROOT/update.log" && ok "rollback message emitted" || bad "no rollback message"
[[ -f "$DEFAULT_APP_DIR/old-marker.txt" ]] && ok "previous application tree restored" || bad "previous application tree not restored"
grep -q '"version":"1.0.0"' "$DEFAULT_APP_DIR/package.json" && ok "restored application reports 1.0.0" || bad "restored version wrong"
compgen -G "$DEFAULT_BACKUP_ROOT/snapshot_*" >/dev/null && ok "snapshot retained for recovery" || bad "snapshot missing"
compgen -G "$DEFAULT_APP_DIR.failed-*" >/dev/null && bad "failed application tree left behind" || ok "failed application tree cleaned up"
grep -q 'no-port-forwarding' "$USER_AUTH_FILE" && ok "authorized_keys untouched by failed update" || bad "failed update altered authorized_keys"

echo "--------------------------------------------------------"
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
