#!/usr/bin/env bash
# ==============================================================================
# Run the full test suite
# ------------------------------------------------------------------------------
# Usage:
#   bash tests/run_all.sh
#   SSHD_BIN=/usr/sbin/sshd SSHD_CLIENT_KEY=... SSHD_HOST_KEY=... bash tests/run_all.sh
#
# A test that exits 0 with a SKIP message is counted as skipped, not passed.
# ==============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

run() {
  local name="$1"
  shift
  echo ""
  echo "=================================================================="
  echo "RUN: $name"
  echo "=================================================================="
  local out
  if out=$("$@" 2>&1); then
    printf '%s\n' "$out"
    if printf '%s' "$out" | grep -q '^SKIP:'; then
      echo "RESULT: SKIP ($name)"
      SKIP=$((SKIP + 1))
    else
      echo "RESULT: PASS ($name)"
      PASS=$((PASS + 1))
    fi
  else
    printf '%s\n' "$out"
    echo "RESULT: FAIL ($name)"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
  fi
}

run "unit: installer core" bash tests/unit/test_installer_core.sh
run "unit: HAOS proxy logic" node tests/unit/test_haos_proxy.js
run "integration: lifecycle" bash tests/integration/test_lifecycle.sh
run "cross-platform matrix (simulated)" bash tests/test_cross_platform_matrix.sh
run "failure recovery" bash tests/test_failure_recovery.sh
run "loopback bind" node tests/test_loopback_bind.js
run "HAOS proxy live" node tests/test_haos_proxy_live.js
run "authorized_keys migration" bash tests/test_migration_logic.sh
run "sshd policy installer" bash tests/test_sshd_policy.sh
run "update rollback" bash tests/test_update_rollback.sh
run "v1.0.0 to v1.0.1 migration" bash tests/test_upgrade_migration.sh
run "HAOS host-key parser" node tests/test_hostkey_parser.js
run "real Account Manager loopback" node tests/test_real_service_loopback.js
run "SSH hardening E2E" bash tests/test_ssh_hardening.sh
run "repository hygiene" node tests/test_repo_hygiene.js

echo ""
echo "=================================================================="
echo "SUMMARY: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -ne 0 ]]; then
  printf 'FAILED: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
echo "=================================================================="
