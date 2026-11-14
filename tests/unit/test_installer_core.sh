#!/usr/bin/env bash
# ==============================================================================
# Unit Tests for Shell Installer Core & Architecture Detection
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/common/common.sh"
# shellcheck source=/dev/null
source "$PROJECT_ROOT/server-installer/lib/installer_core.sh"

PASSED=0
FAILED=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  [PASS] $msg"
    PASSED=$((PASSED + 1))
  else
    echo "  [FAIL] $msg (Expected: '$expected', Actual: '$actual')"
    FAILED=$((FAILED + 1))
  fi
}

assert_match() {
  local pattern="$1"
  local actual="$2"
  local msg="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "  [PASS] $msg"
    PASSED=$((PASSED + 1))
  else
    echo "  [FAIL] $msg (String '$actual' does not match pattern '$pattern')"
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Running Unit Tests: installer_core.sh & common.sh ==="

# Test 1: Architecture detection produces valid value
ARCH=$(detect_architecture)
assert_match "^(amd64|arm64|armhf|unsupported)" "$ARCH" "Detect architecture returns recognized value: $ARCH"

# Test 2: Random secret generator
SECRET=$(generate_random_secret 32)
assert_eq "32" "${#SECRET}" "Secret generator generates exactly 32 hex chars"

# Test 3: Restricted SSH authorized_keys line generation
PUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKey amtunnel@haos"
ENTRY=$(generate_restricted_authorized_key_entry "$PUB" "127.0.0.1" 8320)
assert_match 'command="/bin/false"' "$ENTRY" "Restricted key entry includes command=/bin/false"
assert_match 'no-agent-forwarding' "$ENTRY" "Restricted key entry denies agent forwarding"
assert_match 'no-pty' "$ENTRY" "Restricted key entry denies pty"
assert_match 'permitopen="127.0.0.1:8320"' "$ENTRY" "Restricted key permits forwarding only to 127.0.0.1:8320"
assert_match 'permitlisten="127.0.0.1:1"' "$ENTRY" "Restricted key includes defense-in-depth permitlisten"
assert_match 'AAAAC3NzaC1lZDI1NTE5' "$ENTRY" "Restricted key preserves original public key"

# Test 4: Secret redaction in diagnostics
RAW_LOG="MANAGEMENT_API_KEY=super_secret_value_12345"
REDACTED=$(echo "$RAW_LOG" | redact_sensitive)
assert_match "MANAGEMENT_API_KEY: \[REDACTED\]" "$REDACTED" "Redact sensitive removes sensitive API key values"

echo "--------------------------------------------------------"
echo "Results: $PASSED passed, $FAILED failed."
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
