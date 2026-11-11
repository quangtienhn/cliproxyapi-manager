#!/usr/bin/env bash
# ==============================================================================
# Cross-Platform Simulation Test Matrix for CLIProxyAPI Installer
# Simulates Debian 12/13 (AMD64 & ARM64) and Ubuntu 22.04/24.04 environments
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MATRIX=(
  "debian:12:amd64"
  "debian:12:arm64"
  "debian:13:amd64"
  "debian:13:arm64"
  "ubuntu:22.04:amd64"
  "ubuntu:24.04:amd64"
  "ubuntu:24.04:arm64"
)

TOTAL=0
PASSED=0
FAILED=0

for item in "${MATRIX[@]}"; do
  IFS=':' read -r os ver arch <<< "$item"
  TOTAL=$((TOTAL + 1))
  echo "=========================================================="
  echo "[TEST $TOTAL] Testing Target OS=$os, Version=$ver, Arch=$arch"
  echo "=========================================================="

  SIM_DIR=$(mktemp -d /tmp/installer_compat_XXXXXX)
  
  # Setup mock environment
  mkdir -p "$SIM_DIR/etc" "$SIM_DIR/var/lib/cliproxyapi/auths" "$SIM_DIR/opt"
  cat << EOF > "$SIM_DIR/etc/os-release"
ID=$os
VERSION_ID="$ver"
NAME="$os Linux"
EOF

  export INSTALLER_TEST_MODE=1
  export MOCK_ARCH="$arch"
  export DEFAULT_APP_DIR="$SIM_DIR/opt/cliproxyapi-account-manager"
  export DEFAULT_CONFIG_DIR="$SIM_DIR/etc/cliproxyapi-account-manager"
  export DEFAULT_LOG_DIR="$SIM_DIR/var/log/cliproxyapi-account-manager"
  export DEFAULT_DATA_DIR="$SIM_DIR/var/lib/cliproxyapi-account-manager"
  export DEFAULT_BACKUP_ROOT="$SIM_DIR/var/backups/cliproxyapi-account-manager"
  export DEFAULT_CLIPROXY_CONFIG="$SIM_DIR/etc/cliproxyapi/config.yaml"
  export DEFAULT_AUTH_DIR="$SIM_DIR/var/lib/cliproxyapi/auths"
  export BACKUP_DIR="$DEFAULT_BACKUP_ROOT"

  # 1. Fresh Install
  if bash "$PROJECT_ROOT/server-installer/install.sh" --non-interactive >/dev/null 2>&1; then
    # Verify installation results
    if [[ -d "$DEFAULT_APP_DIR/src" && -f "$DEFAULT_CONFIG_DIR/manager.env" ]]; then
      echo "  -> Fresh install: OK"
    else
      echo "  -> Fresh install: FAILED (missing files)"
      FAILED=$((FAILED + 1))
      rm -rf "$SIM_DIR"
      continue
    fi
  else
    echo "  -> Fresh install script failed!"
    FAILED=$((FAILED + 1))
    rm -rf "$SIM_DIR"
    continue
  fi

  # 2. Idempotency (Second run in place)
  if bash "$PROJECT_ROOT/server-installer/install.sh" --non-interactive >/dev/null 2>&1; then
    echo "  -> Idempotent re-run: OK"
  else
    echo "  -> Idempotent re-run: FAILED!"
    FAILED=$((FAILED + 1))
    rm -rf "$SIM_DIR"
    continue
  fi

  # 3. Diagnostics Generation
  DIAG=$(bash "$PROJECT_ROOT/server-installer/diagnostics.sh" 2>/dev/null || true)
  if echo "$DIAG" | grep -q "SYSTEM ENVIRONMENT"; then
    echo "  -> Diagnostics generation: OK"
  else
    echo "  -> Diagnostics generation: FAILED!"
    FAILED=$((FAILED + 1))
    rm -rf "$SIM_DIR"
    continue
  fi

  PASSED=$((PASSED + 1))
  rm -rf "$SIM_DIR"
done

echo "=========================================================="
echo "Cross-Platform Matrix Results: $PASSED / $TOTAL passed."
echo "=========================================================="

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
