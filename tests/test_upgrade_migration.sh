#!/usr/bin/env bash
# ==============================================================================
# Complete Upgrade Migration Test: v1.0.0 -> v1.0.3
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/upgrade_migration_XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== Running Upgrade Migration Simulation: v1.0.0 -> v1.0.3 ==="

export INSTALLER_TEST_MODE=1
export DEFAULT_APP_DIR="$TEST_ROOT/opt/cliproxyapi-account-manager"
export DEFAULT_CONFIG_DIR="$TEST_ROOT/etc/cliproxyapi-account-manager"
export DEFAULT_LOG_DIR="$TEST_ROOT/var/log/cliproxyapi-account-manager"
export DEFAULT_DATA_DIR="$TEST_ROOT/var/lib/cliproxyapi-account-manager"
export DEFAULT_BACKUP_ROOT="$TEST_ROOT/var/backups/cliproxyapi-account-manager"
export DEFAULT_CLIPROXY_CONFIG="$TEST_ROOT/etc/cliproxyapi/config.yaml"
export DEFAULT_AUTH_DIR="$TEST_ROOT/var/lib/cliproxyapi/auths"
export BACKUP_DIR="$DEFAULT_BACKUP_ROOT"
export USER_AUTH_FILE="$TEST_ROOT/home/amtunnel/.ssh/authorized_keys"

mkdir -p "$(dirname "$USER_AUTH_FILE")" "$DEFAULT_APP_DIR/src" "$DEFAULT_CONFIG_DIR" "$DEFAULT_AUTH_DIR" "$DEFAULT_BACKUP_ROOT"
printf 'OLD_V1_0_0_MARKER\n' > "$DEFAULT_APP_DIR/old-version-marker.txt"

# 1. Simulate a v1.0.0 installation.
cat << 'EOF' > "$USER_AUTH_FILE"
# Administrator key (must remain byte-for-byte identical)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminKey12345 operator@desktop

# Legacy v1.0.0 tunnel key with no-port-forwarding
command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITunnelKey67890 amtunnel@haos

# CI deployment key
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCThirdPartyKey ci@runner
EOF

# v1.0.0 template exposed the UI on every interface.
cat << 'EOF' > "$DEFAULT_CONFIG_DIR/manager.env"
PORT=8320
HOST=0.0.0.0
ADMIN_USERNAME=admin
ADMIN_PASSWORD_HASH=existing_hash
CLIPROXYAPI_MANAGEMENT_KEY=existing_secret_value
EOF

cat << 'EOF' > "$DEFAULT_AUTH_DIR/google-user.json"
{"provider": "google", "account": "test@example.com", "token": "placeholder"}
EOF

cat << 'EOF' > "$DEFAULT_APP_DIR/package.json"
{"name": "cliproxyapi-account-manager", "version": "1.0.0"}
EOF

ADMIN_LINE_BEFORE=$(grep 'operator@desktop' "$USER_AUTH_FILE")
CI_LINE_BEFORE=$(grep 'ci@runner' "$USER_AUTH_FILE")
ENV_HASH_BEFORE_MIGRATION=$(sha256sum "$DEFAULT_CONFIG_DIR/manager.env" | awk '{print $1}')

echo "[PHASE 1] Initial v1.0.0 environment established."

# 2. Run update.sh
echo "[PHASE 2] Executing update workflow to v1.0.3..."
if ! bash "$PROJECT_ROOT/server-installer/update.sh"; then
  echo "FAIL: update.sh exited non-zero" >&2
  exit 1
fi

# 3. Verify migration outcomes.
echo "[PHASE 3] Verifying migration outcomes..."

if grep -v '^[[:space:]]*#' "$USER_AUTH_FILE" | grep 'amtunnel@haos' | grep -q 'no-port-forwarding'; then
  bad "legacy no-port-forwarding still present in tunnel key"
else
  ok "legacy no-port-forwarding removed from tunnel key"
fi

if grep 'amtunnel@haos' "$USER_AUTH_FILE" | grep -q 'permitlisten="127.0.0.1:1"'; then
  ok "hardened permitlisten applied"
else
  bad "permitlisten not applied to tunnel key"
fi

if grep 'amtunnel@haos' "$USER_AUTH_FILE" | grep -q 'permitopen="127.0.0.1:8320"'; then
  ok "permitopen preserved"
else
  bad "permitopen missing"
fi

[[ "$(grep 'operator@desktop' "$USER_AUTH_FILE")" == "$ADMIN_LINE_BEFORE" ]] \
  && ok "unrelated admin key preserved byte-for-byte" || bad "admin key changed"
[[ "$(grep 'ci@runner' "$USER_AUTH_FILE")" == "$CI_LINE_BEFORE" ]] \
  && ok "unrelated CI key preserved byte-for-byte" || bad "CI key changed"

if grep -qx 'HOST=127.0.0.1' "$DEFAULT_CONFIG_DIR/manager.env"; then
  ok "update migrated HOST=0.0.0.0 to loopback-only"
else
  bad "update did not enforce loopback binding"
fi
grep -qx 'CLIPROXYAPI_MANAGEMENT_KEY=existing_secret_value' "$DEFAULT_CONFIG_DIR/manager.env" \
  && ok "existing management secret preserved" || bad "management secret was lost"
compgen -G "$DEFAULT_CONFIG_DIR/manager.env.bak.bind.*" >/dev/null \
  && ok "bind migration created a backup" || bad "bind migration created no backup"

grep -q 'test@example.com' "$DEFAULT_AUTH_DIR/google-user.json" \
  && ok "OAuth credentials preserved" || bad "OAuth data was wiped"

if [[ ! -f "$DEFAULT_APP_DIR/old-version-marker.txt" ]]; then
  ok "application tree was replaced with v1.0.3"
else
  bad "old application tree was not replaced"
fi
grep -q '"version": "1.0.3"' "$DEFAULT_APP_DIR/package.json" \
  && ok "deployed application reports version 1.0.3" || bad "deployed version is not 1.0.3"

compgen -G "$DEFAULT_BACKUP_ROOT/snapshot_*" >/dev/null \
  && ok "pre-update snapshot created" || bad "pre-update snapshot missing"

# 4. Idempotency: a second update must not duplicate or mutate keys.
HASH1=$(sha256sum "$USER_AUTH_FILE" | awk '{print $1}')
bash "$PROJECT_ROOT/server-installer/update.sh" >/dev/null 2>&1
HASH2=$(sha256sum "$USER_AUTH_FILE" | awk '{print $1}')
[[ "$HASH1" == "$HASH2" ]] && ok "second update leaves authorized_keys unchanged" || bad "second update mutated authorized_keys"
[[ "$(grep -c 'amtunnel@haos' "$USER_AUTH_FILE")" -eq 1 ]] && ok "no duplicate tunnel key after second update" || bad "duplicate tunnel key"

# 5. No private key or secret material in update output.
LOG=$(bash "$PROJECT_ROOT/server-installer/update.sh" 2>&1 || true)
if printf '%s' "$LOG" | grep -qE 'BEGIN (OPENSSH|RSA|EC) PRIVATE KEY|existing_secret_value'; then
  bad "update output leaked private key or management secret"
else
  ok "update output contains no private key or management secret"
fi

echo "--------------------------------------------------------"
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
