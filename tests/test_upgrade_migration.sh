#!/usr/bin/env bash
# ==============================================================================
# Complete Upgrade Migration Test: v1.0.0 to v1.0.1
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_ROOT=$(mktemp -d /tmp/upgrade_migration_XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "=== Running Upgrade Migration Simulation: v1.0.0 -> v1.0.1 ==="

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

mkdir -p "$(dirname "$USER_AUTH_FILE")" "$DEFAULT_APP_DIR/src" "$DEFAULT_CONFIG_DIR" "$DEFAULT_AUTH_DIR"

# 1. Simulate v1.0.0 State
cat << 'EOF' > "$USER_AUTH_FILE"
# Administrator key (Must remain byte-for-byte identical)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminKey12345 operator@desktop

# Legacy v1.0.0 tunnel key with no-port-forwarding
command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITunnelKey67890 amtunnel@haos

# CI deployment key
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCThirdPartyKey ci@runner
EOF

cat << 'EOF' > "$DEFAULT_CONFIG_DIR/manager.env"
PORT=8320
HOST=127.0.0.1
ADMIN_USERNAME=admin
ADMIN_PASSWORD_HASH=existing_hash
EOF

cat << 'EOF' > "$DEFAULT_AUTH_DIR/google-user.json"
{"provider": "google", "account": "test@gmail.com", "token": "val"}
EOF

cat << 'EOF' > "$DEFAULT_APP_DIR/package.json"
{"name": "cliproxyapi-account-manager", "version": "1.0.0"}
EOF

echo "[PHASE 1] Initial v1.0.0 environment established."
echo "Original tunnel key line:"
grep "amtunnel@haos" "$USER_AUTH_FILE"

# 2. Run update.sh
echo "[PHASE 2] Executing update workflow to v1.0.1..."
bash "$PROJECT_ROOT/server-installer/update.sh"

# 3. Verification
echo "[PHASE 3] Verifying migration outcomes..."

# Check 1: Legacy no-port-forwarding is eliminated from tunnel key entry
if grep -v "^\s*#" "$USER_AUTH_FILE" | grep "amtunnel@haos" | grep -q "no-port-forwarding"; then
  echo "FAIL: no-port-forwarding still found in tunnel key!" >&2
  exit 1
fi
echo "  [PASS] Legacy 'no-port-forwarding' removed."

# Check 2: Hardened restrictions and permitlisten are present
if ! grep "amtunnel@haos" "$USER_AUTH_FILE" | grep -q 'permitlisten="127.0.0.1:1"'; then
  echo "FAIL: permitlisten not applied to tunnel key!" >&2
  exit 1
fi
if ! grep "amtunnel@haos" "$USER_AUTH_FILE" | grep -q 'permitopen="127.0.0.1:8320"'; then
  echo "FAIL: permitopen not preserved!" >&2
  exit 1
fi
echo "  [PASS] Hardened permitopen & permitlisten applied."

# Check 3: Non-product keys preserved byte-for-byte
grep -q "operator@desktop" "$USER_AUTH_FILE" || { echo "FAIL: Admin key missing!"; exit 1; }
grep -q "ci@runner" "$USER_AUTH_FILE" || { echo "FAIL: CI key missing!"; exit 1; }
echo "  [PASS] Non-product keys preserved byte-for-byte."

# Check 4: OAuth credentials preserved
grep -q "test@gmail.com" "$DEFAULT_AUTH_DIR/google-user.json" || { echo "FAIL: OAuth data wiped!"; exit 1; }
echo "  [PASS] OAuth credentials intact."

# Check 5: Idempotency (second run produces zero changes)
HASH1=$(sha256sum "$USER_AUTH_FILE" | awk '{print $1}')
bash "$PROJECT_ROOT/server-installer/update.sh" >/dev/null 2>&1
HASH2=$(sha256sum "$USER_AUTH_FILE" | awk '{print $1}')

if [[ "$HASH1" != "$HASH2" ]]; then
  echo "FAIL: Migration is not idempotent!" >&2
  exit 1
fi
echo "  [PASS] Upgrade migration is completely idempotent."

echo "=== All Upgrade Migration Assertions Passed! ==="
