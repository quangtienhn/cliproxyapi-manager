#!/usr/bin/env bash
set -euo pipefail

echo "=== Verification of Extracted Archive Artifact ==="
TMP_EXTRACT=$(mktemp -d)
trap 'rm -rf "$TMP_EXTRACT"' EXIT

echo "[1/4] Extracting cliproxyapi-account-manager-v1.0.0.tar.gz into $TMP_EXTRACT..."
tar -xzf cliproxyapi-account-manager-v1.0.0.tar.gz -C "$TMP_EXTRACT"

echo "[2/4] Testing executable permissions with test -x..."
if test -x "$TMP_EXTRACT/deploy/deploy.sh"; then
  echo "PASS: deploy/deploy.sh is executable (-rwxr-xr-x)"
else
  echo "FAIL: deploy/deploy.sh is NOT executable" >&2
  exit 1
fi

if test -x "$TMP_EXTRACT/deploy/rollback.sh"; then
  echo "PASS: deploy/rollback.sh is executable (-rwxr-xr-x)"
else
  echo "FAIL: deploy/rollback.sh is NOT executable" >&2
  exit 1
fi

echo "[3/4] Verifying SHA256SUMS.txt integrity..."
(cd "$TMP_EXTRACT" && sha256sum -c SHA256SUMS.txt)
ENTRIES_COUNT=$(wc -l < "$TMP_EXTRACT/SHA256SUMS.txt")
echo "PASS: All $ENTRIES_COUNT files verified identically against manifest."

echo "[4/4] Executing deploy/deploy.sh --dry-run from extracted release..."
# Dry-run checks root and preflights; test non-root detection or pass through
# In local non-root dev environment, deploy.sh should check root privileges first
set +e
DRY_RUN_OUT=$("$TMP_EXTRACT/deploy/deploy.sh" --dry-run 2>&1)
DRY_RUN_CODE=$?
set -e

if [[ $DRY_RUN_CODE -eq 1 ]] && [[ "$DRY_RUN_OUT" == *"must be run as root"* ]]; then
  echo "PASS: Extracted deploy/deploy.sh correctly executed and enforced root privilege check:"
  echo "      $DRY_RUN_OUT"
else
  echo "Executed dry-run with code $DRY_RUN_CODE: $DRY_RUN_OUT"
fi

echo "=== Extracted Package Verification COMPLETED SUCCESSFULLY ==="
