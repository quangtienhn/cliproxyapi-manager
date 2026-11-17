#!/usr/bin/env bash
# ==============================================================================
# Bash Regression Test Suite: Strict Service State Parser & Safety Boundaries
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source strict parser
source "$PKG_ROOT/deploy/parse_state.inc.sh"

echo "=== Running Bash Strict Parser Regression Tests ==="

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Test 1: Valid metadata parsing
echo -n "Test 1: Valid state file... "
VALID_FILE="$TMP_DIR/valid.env"
cat << 'EOF' > "$VALID_FILE"
WAS_ENABLED=yes
WAS_ACTIVE=no
EOF
OUTPUT=$(parse_service_state_strict "$VALID_FILE")
if [[ "$OUTPUT" == *"WAS_ENABLED=yes"* ]] && [[ "$OUTPUT" == *"WAS_ACTIVE=no"* ]]; then
  echo "PASS"
else
  echo "FAIL: Unexpected output: $OUTPUT" >&2
  exit 1
fi

# Test 2: Missing key rejection
echo -n "Test 2: Missing key rejection... "
MISSING_FILE="$TMP_DIR/missing.env"
cat << 'EOF' > "$MISSING_FILE"
WAS_ENABLED=yes
EOF
if parse_service_state_strict "$MISSING_FILE" >/dev/null 2>&1; then
  echo "FAIL: Expected rejection of missing key" >&2
  exit 1
else
  echo "PASS"
fi

# Test 3: Duplicate key rejection
echo -n "Test 3: Duplicate key rejection... "
DUP_FILE="$TMP_DIR/duplicate.env"
cat << 'EOF' > "$DUP_FILE"
WAS_ENABLED=yes
WAS_ENABLED=no
WAS_ACTIVE=yes
EOF
if parse_service_state_strict "$DUP_FILE" >/dev/null 2>&1; then
  echo "FAIL: Expected rejection of duplicate key" >&2
  exit 1
else
  echo "PASS"
fi

# Test 4: Unknown key rejection
echo -n "Test 4: Unknown key rejection... "
UNKNOWN_FILE="$TMP_DIR/unknown.env"
cat << 'EOF' > "$UNKNOWN_FILE"
WAS_ENABLED=yes
WAS_ACTIVE=yes
UNKNOWN_VAR=test
EOF
if parse_service_state_strict "$UNKNOWN_FILE" >/dev/null 2>&1; then
  echo "FAIL: Expected rejection of unknown key" >&2
  exit 1
else
  echo "PASS"
fi

# Test 5: Malicious shell syntax rejection & non-execution
echo -n "Test 5: Malicious shell syntax rejection (no execution)... "
MARKER_FILE="$TMP_DIR/hacked.marker"
MALICIOUS_FILE="$TMP_DIR/malicious.env"
cat << EOF > "$MALICIOUS_FILE"
WAS_ENABLED=yes; touch "$MARKER_FILE"
WAS_ACTIVE=\$(touch "$MARKER_FILE")
EOF

if parse_service_state_strict "$MALICIOUS_FILE" >/dev/null 2>&1; then
  echo "FAIL: Expected parser failure on shell syntax" >&2
  exit 1
fi

if [[ -f "$MARKER_FILE" ]]; then
  echo "FAIL: Malicious shell syntax was EXECUTED!" >&2
  exit 1
else
  echo "PASS (command never executed)"
fi

echo "=== All Bash Strict Parser Regression Tests PASSED ==="
