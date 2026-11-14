#!/usr/bin/env bash
# ==============================================================================
# Installer core regression tests: authorized_keys handling and loopback bind
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/common/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/server-installer/lib/installer_core.sh"

PASS=0
FAIL=0
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/installer_core.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

TUNNEL_PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITunnelKey456 amtunnel@haos'
ADMIN_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminKey123 operator@workstation'
THIRD_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCOtherKey backup@nas'

echo "=== authorized_keys migration ==="
AUTH="$TEST_ROOT/authorized_keys"
cat > "$AUTH" <<EOF
# Operator admin key - must never change
$ADMIN_KEY

# v1.0.0 buggy tunnel key (comment mentions no-port-forwarding on purpose)
command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320" $TUNNEL_PUB

# Third-party backup key
$THIRD_KEY

# Another legacy tunnel key for a different target must be left alone
command="/bin/false",no-port-forwarding,permitopen="127.0.0.1:9999" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherTunnel other@tunnel
EOF

ADMIN_LINE_BEFORE=$(grep -F "$ADMIN_KEY" "$AUTH")
THIRD_LINE_BEFORE=$(grep -F "$THIRD_KEY" "$AUTH")
OTHER_TUNNEL_BEFORE=$(grep -F '127.0.0.1:9999' "$AUTH")

migrate_authorized_keys_file "$AUTH" "127.0.0.1" 8320

grep -qF "$ADMIN_LINE_BEFORE" "$AUTH" && ok "unrelated admin key preserved byte-for-byte" || bad "admin key changed"
grep -qF "$THIRD_LINE_BEFORE" "$AUTH" && ok "unrelated third-party key preserved byte-for-byte" || bad "third-party key changed"
grep -qF "$OTHER_TUNNEL_BEFORE" "$AUTH" && ok "key for a different target left untouched" || bad "different-target key was modified"

KEY_ENTRY=$(grep 'amtunnel@haos' "$AUTH")
if [[ "$KEY_ENTRY" != *"no-port-forwarding"* ]]; then ok "legacy no-port-forwarding removed from tunnel key"; else bad "no-port-forwarding still present"; fi
[[ "$KEY_ENTRY" == *'permitopen="127.0.0.1:8320"'* ]] && ok "permitopen preserved" || bad "permitopen missing"
[[ "$KEY_ENTRY" == *'permitlisten="127.0.0.1:1"'* ]] && ok "permitlisten defense-in-depth present" || bad "permitlisten missing"
[[ "$KEY_ENTRY" == *'command="/bin/false"'* ]] && ok "forced command still present" || bad "forced command missing"
[[ "$(grep -c 'amtunnel@haos' "$AUTH")" -eq 1 ]] && ok "no duplicated tunnel key" || bad "tunnel key duplicated"

BACKUPS=$(find "$TEST_ROOT" -maxdepth 1 -name 'authorized_keys.bak.*' | wc -l | tr -d ' ')
[[ "$BACKUPS" -eq 1 ]] && ok "exactly one backup created" || bad "expected 1 backup, found $BACKUPS"

HASH_BEFORE=$(sha256sum "$AUTH" | awk '{print $1}')
migrate_authorized_keys_file "$AUTH" "127.0.0.1" 8320
HASH_AFTER=$(sha256sum "$AUTH" | awk '{print $1}')
BACKUPS_AFTER=$(find "$TEST_ROOT" -maxdepth 1 -name 'authorized_keys.bak.*' | wc -l | tr -d ' ')
[[ "$HASH_BEFORE" == "$HASH_AFTER" ]] && ok "migration is idempotent" || bad "second migration changed the file"
[[ "$BACKUPS" == "$BACKUPS_AFTER" ]] && ok "idempotent run creates no extra backup" || bad "second run created another backup"

echo "=== authorized_keys append preserves existing keys ==="
APPEND="$TEST_ROOT/append_keys"
printf '%s\n' "$ADMIN_KEY" > "$APPEND"
append_restricted_authorized_key "$APPEND" "$TUNNEL_PUB" "127.0.0.1" 8320 >/dev/null
append_restricted_authorized_key "$APPEND" "$TUNNEL_PUB" "127.0.0.1" 8320 >/dev/null
grep -qF "$ADMIN_KEY" "$APPEND" && ok "existing key preserved during append" || bad "existing key lost"
[[ "$(grep -c 'amtunnel@haos' "$APPEND")" -eq 1 ]] && ok "append de-duplicates the same key" || bad "duplicate key appended"

echo "=== loopback bind enforcement ==="
ENV1="$TEST_ROOT/manager.env"
printf 'PORT=8320\nHOST=0.0.0.0\nADMIN_USERNAME=admin\n' > "$ENV1"
enforce_loopback_bind "$ENV1" >/dev/null
grep -qx 'HOST=127.0.0.1' "$ENV1" && ok "HOST=0.0.0.0 rewritten to 127.0.0.1" || bad "HOST was not rewritten"
grep -qx 'PORT=8320' "$ENV1" && ok "unrelated environment values preserved" || bad "unrelated environment value lost"
if compgen -G "$ENV1.bak.bind.*" >/dev/null; then ok "bind change creates a backup"; else bad "bind change did not create a backup"; fi

ENV2="$TEST_ROOT/no_host.env"
printf 'PORT=8320\n' > "$ENV2"
enforce_loopback_bind "$ENV2" >/dev/null
grep -qx 'HOST=127.0.0.1' "$ENV2" && ok "missing HOST defaults to 127.0.0.1" || bad "missing HOST not added"

ENV3="$TEST_ROOT/good.env"
printf 'HOST=127.0.0.1\n' > "$ENV3"
H3=$(sha256sum "$ENV3" | awk '{print $1}')
enforce_loopback_bind "$ENV3" >/dev/null
[[ "$H3" == "$(sha256sum "$ENV3" | awk '{print $1}')" ]] && ok "already-loopback config left unchanged" || bad "loopback config modified"

echo "--------------------------------------------------------"
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
