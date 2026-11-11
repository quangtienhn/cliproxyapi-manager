#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/common/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/server-installer/lib/installer_core.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/migrate_snippet.sh"

TEST_AUTH=$(mktemp /tmp/test_auth_keys_XXXXXX)
trap 'rm -f "$TEST_AUTH"*' EXIT

# Populate test authorized_keys
cat << 'EOF' > "$TEST_AUTH"
# Operator admin key - MUST NOT BE TOUCHED
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminKey123 operator@workstation

# v1.0.0 buggy tunnel key with no-port-forwarding
command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITunnelKey456 amtunnel@haos

# Another third-party key
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCOtherKey backup@nas
EOF

echo "Original file:"
cat "$TEST_AUTH"
echo "----------------------------------------"

migrate_authorized_keys_file "$TEST_AUTH" "127.0.0.1" 8320

echo "Migrated file:"
cat "$TEST_AUTH"
echo "----------------------------------------"

# Assertions
grep -q "operator@workstation" "$TEST_AUTH" || { echo "FAIL: Admin key lost!"; exit 1; }
grep -q "backup@nas" "$TEST_AUTH" || { echo "FAIL: Third-party key lost!"; exit 1; }
! grep -v "^\s*#" "$TEST_AUTH" | grep -q "no-port-forwarding" || { echo "FAIL: no-port-forwarding still present in key entries!"; exit 1; }
grep -q "permitlisten=\"127.0.0.1:1\"" "$TEST_AUTH" || { echo "FAIL: permitlisten not added!"; exit 1; }

# Idempotency: Run second time
ORIG_HASH=$(sha256sum "$TEST_AUTH" | awk '{print $1}')
migrate_authorized_keys_file "$TEST_AUTH" "127.0.0.1" 8320
NEW_HASH=$(sha256sum "$TEST_AUTH" | awk '{print $1}')

if [[ "$ORIG_HASH" != "$NEW_HASH" ]]; then
  echo "FAIL: Migration was not idempotent!"
  exit 1
fi

echo "PASS: Migration verified and idempotent."
