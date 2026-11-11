#!/usr/bin/env bash
# ==============================================================================
# Integration Lifecycle Test (Isolated Staging Directory Simulation)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_ROOT=$(mktemp -d /tmp/easy_installer_sim_XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "=== Running Integration Simulation in $TEST_ROOT ==="

export INSTALLER_TEST_MODE=1
export DEFAULT_APP_DIR="$TEST_ROOT/opt/cliproxyapi-account-manager"
export DEFAULT_CONFIG_DIR="$TEST_ROOT/etc/cliproxyapi-account-manager"
export DEFAULT_LOG_DIR="$TEST_ROOT/var/log/cliproxyapi-account-manager"
export DEFAULT_DATA_DIR="$TEST_ROOT/var/lib/cliproxyapi-account-manager"
export DEFAULT_BACKUP_ROOT="$TEST_ROOT/var/backups/cliproxyapi-account-manager"
export DEFAULT_CLIPROXY_CONFIG="$TEST_ROOT/etc/cliproxyapi/config.yaml"
export DEFAULT_AUTH_DIR="$TEST_ROOT/var/lib/cliproxyapi/auths"
export BACKUP_DIR="$DEFAULT_BACKUP_ROOT"

# Pre-populate synthetic CLIProxyAPI environment
mkdir -p "$(dirname "$DEFAULT_CLIPROXY_CONFIG")" "$DEFAULT_AUTH_DIR"
cat << 'EOF' > "$DEFAULT_CLIPROXY_CONFIG"
server:
  port: 8317
management:
  allow-remote: false
  secret: initial_cliproxy_secret_test
EOF

cat << 'EOF' > "$DEFAULT_AUTH_DIR/codex-user1.json"
{"provider": "codex", "account": "user1@example.com", "access_token": "test_tok", "refresh_token": "test_ref"}
EOF

# 1. Fresh Install Test
echo "[STEP 1] Testing fresh installation..."
bash "$PROJECT_ROOT/server-installer/install.sh" --non-interactive

if [[ ! -d "$DEFAULT_APP_DIR/src" ]]; then
  echo "[FAIL] App directory not populated!" >&2
  exit 1
fi

if [[ ! -f "$DEFAULT_CONFIG_DIR/manager.env" ]]; then
  echo "[FAIL] manager.env not created!" >&2
  exit 1
fi
echo "[OK] Fresh installation verified."

# Verify OAuth preservation
if [[ ! -f "$DEFAULT_AUTH_DIR/codex-user1.json" ]]; then
  echo "[FAIL] OAuth credentials lost during install!" >&2
  exit 1
fi
echo "[OK] OAuth credentials intact."

# 2. Backup Test
echo "[STEP 2] Testing backup workflow..."
BACKUP_OUTPUT=$(bash "$PROJECT_ROOT/server-installer/backup.sh")
BACKUP_PATH=$(echo "$BACKUP_OUTPUT" | tail -n1 | tr -d '\r\n')

if [[ ! -d "$BACKUP_PATH" || ! -f "$BACKUP_PATH/SHA256SUMS.txt" ]]; then
  echo "[FAIL] Backup artifact not created: $BACKUP_PATH" >&2
  exit 1
fi

if [[ ! -f "$BACKUP_PATH/auths/codex-user1.json" ]]; then
  echo "[FAIL] OAuth data not included in backup!" >&2
  exit 1
fi
echo "[OK] Backup created and verified with checksums: $BACKUP_PATH"

# 3. Modify data and test Restore
echo "[STEP 3] Mutating configuration and testing restore..."
echo "CORRUPTED_KEY=invalid" > "$DEFAULT_CONFIG_DIR/manager.env"
rm -f "$DEFAULT_AUTH_DIR/codex-user1.json"

bash "$PROJECT_ROOT/server-installer/restore.sh" "$BACKUP_PATH"

if ! grep -q "CLIPROXYAPI_URL" "$DEFAULT_CONFIG_DIR/manager.env"; then
  echo "[FAIL] manager.env not restored properly!" >&2
  exit 1
fi

if [[ ! -f "$DEFAULT_AUTH_DIR/codex-user1.json" ]]; then
  echo "[FAIL] OAuth credentials not restored!" >&2
  exit 1
fi
echo "[OK] Restore verified successfully."

# 4. Diagnostics Test (Verification of secret redaction)
echo "[STEP 4] Testing diagnostics and secret redaction..."
DIAG_REPORT=$(bash "$PROJECT_ROOT/server-installer/diagnostics.sh")
if echo "$DIAG_REPORT" | grep -q "initial_cliproxy_secret_test"; then
  echo "[FAIL] Sensitive secret leaked in diagnostics report!" >&2
  exit 1
fi
echo "[OK] Diagnostics test passed; secrets properly redacted."

# 5. Uninstall Test
echo "[STEP 5] Testing safe uninstall (preserving OAuth)..."
bash "$PROJECT_ROOT/server-installer/uninstall.sh" --force

if [[ -d "$DEFAULT_APP_DIR" ]]; then
  echo "[FAIL] App directory was not removed!" >&2
  exit 1
fi

if [[ ! -f "$DEFAULT_AUTH_DIR/codex-user1.json" ]]; then
  echo "[FAIL] Safe uninstall improperly deleted OAuth credentials!" >&2
  exit 1
fi
echo "[OK] Safe uninstall preserved credentials and removed application."

echo "=== All integration lifecycle tests passed! ==="
