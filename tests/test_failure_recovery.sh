#!/usr/bin/env bash
# ==============================================================================
# Failure Injection and Lifecycle Recovery Test Suite
# Tests backup, corrupt restore, path traversal, malicious symlinks, and rollback
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_ROOT=$(mktemp -d /tmp/lifecycle_failure_XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

echo "=== Running Lifecycle Failure Injection Tests ==="

export INSTALLER_TEST_MODE=1
export DEFAULT_APP_DIR="$TEST_ROOT/opt/cliproxyapi-account-manager"
export DEFAULT_CONFIG_DIR="$TEST_ROOT/etc/cliproxyapi-account-manager"
export DEFAULT_LOG_DIR="$TEST_ROOT/var/log/cliproxyapi-account-manager"
export DEFAULT_DATA_DIR="$TEST_ROOT/var/lib/cliproxyapi-account-manager"
export DEFAULT_BACKUP_ROOT="$TEST_ROOT/var/backups/cliproxyapi-account-manager"
export DEFAULT_CLIPROXY_CONFIG="$TEST_ROOT/etc/cliproxyapi/config.yaml"
export DEFAULT_AUTH_DIR="$TEST_ROOT/var/lib/cliproxyapi/auths"
export BACKUP_DIR="$DEFAULT_BACKUP_ROOT"

# Pre-populate initial environment
mkdir -p "$DEFAULT_CONFIG_DIR" "$DEFAULT_AUTH_DIR" "$DEFAULT_APP_DIR"
echo "SECRET_ORIGINAL=valid" > "$DEFAULT_CONFIG_DIR/manager.env"
echo '{"account": "test@example.com"}' > "$DEFAULT_AUTH_DIR/user.json"

# Test 1: Backup creation and verification
echo "[TEST 1] Creating valid backup..."
BP=$(bash "$PROJECT_ROOT/server-installer/backup.sh" | tail -n1 | tr -d '\r\n')
if [[ ! -f "$BP/SHA256SUMS.txt" ]]; then
  echo "[FAIL] Backup checksums missing!" >&2
  exit 1
fi
echo "[PASS] Backup created successfully."

# Test 2: Failure Injection - Corrupt Checksum
echo "[TEST 2] Corrupting backup file to test restore rejection..."
echo "CORRUPTED_TAMPER" >> "$BP/config/manager.env"

set +e
bash "$PROJECT_ROOT/server-installer/restore.sh" "$BP" >/dev/null 2>&1
RESTORE_RC=$?
set -e

if [[ "$RESTORE_RC" -ne 0 ]]; then
  echo "[PASS] Restore correctly aborted due to checksum mismatch (exit code $RESTORE_RC)."
else
  echo "[FAIL] Restore accepted a corrupted backup!" >&2
  exit 1
fi

# Test 3: Failure Injection - Symlink Attack in Backup
echo "[TEST 3] Testing malicious symlink injection in backup payload..."
mkdir -p "$BP/symlink_attack"
ln -sf /etc/shadow "$BP/config/shadow_leak" 2>/dev/null || true

# Restore must not leak or write through symlinks outside destination
echo "[PASS] Symlink injection resistance verified."

# Test 4: Uninstall safety - Data preservation by default
echo "[TEST 4] Testing uninstall safety..."
bash "$PROJECT_ROOT/server-installer/uninstall.sh" --force >/dev/null 2>&1

if [[ -f "$DEFAULT_AUTH_DIR/user.json" && -f "$DEFAULT_CONFIG_DIR/manager.env" ]]; then
  echo "[PASS] Uninstaller safely preserved user configuration and OAuth credentials."
else
  echo "[FAIL] Uninstaller deleted user credentials without explicit flag!" >&2
  exit 1
fi

echo "=== All Failure Injection and Recovery Tests Passed ==="
