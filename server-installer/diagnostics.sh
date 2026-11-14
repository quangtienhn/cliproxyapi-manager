#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Safe Diagnostics Script
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
COMMON_DIR="$SCRIPT_DIR/../common"

# shellcheck source=/dev/null
source "$COMMON_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/installer_core.sh"

echo "=================================================================="
echo "    CLIProxyAPI Account Manager System Diagnostics               "
echo "=================================================================="
echo "Generated at: $(date -u)"
echo ""

# 1. Host and Architecture
echo "--- 1. SYSTEM ENVIRONMENT ---"
echo "OS: $(detect_os)"
echo "Arch: $(detect_architecture)"
echo "Node: $(node -v 2>/dev/null || echo 'not installed')"
echo "Kernel: $(uname -r 2>/dev/null || echo 'unknown')"
echo ""

# 2. Service Status
echo "--- 2. SERVICE STATUS ---"
if command -v systemctl >/dev/null 2>&1; then
  echo "Account Manager Service: $(systemctl is-active "$DEFAULT_AM_SERVICE" 2>/dev/null || echo 'inactive/unknown')"
  echo "CLIProxyAPI Service:     $(systemctl is-active "$DEFAULT_CLIPROXY_SERVICE" 2>/dev/null || echo 'inactive/not-installed')"
else
  echo "systemctl unavailable"
fi
echo ""

# 3. Port & Listening Sockets
echo "--- 3. PORT & NETWORK LISTENERS ---"
if command -v ss >/dev/null 2>&1; then
  AM_LISTENERS=$(ss -ltn 2>/dev/null | awk -v p=":${DEFAULT_PORT}" '$4 ~ p"$" {print $4}')
  if [[ -z "$AM_LISTENERS" ]]; then
    echo "Account Manager (port $DEFAULT_PORT): not listening"
    echo "  Action: systemctl status $DEFAULT_AM_SERVICE"
  else
    echo "Account Manager (port $DEFAULT_PORT) listeners:"
    printf '  %s\n' "$AM_LISTENERS"
    if printf '%s\n' "$AM_LISTENERS" | grep -qE '^(0\.0\.0\.0|\*|\[::\]):'; then
      echo "  [WARN] Account Manager is exposed on a wildcard address. Expected 127.0.0.1 only."
      echo "  Action: set HOST=127.0.0.1 in $DEFAULT_CONFIG_DIR/manager.env and restart the service."
    else
      echo "  [OK] Account Manager is loopback-only."
    fi
  fi
  CLI_LISTENERS=$(ss -ltn 2>/dev/null | awk '$4 ~ ":8317$" {print $4}')
  if [[ -z "$CLI_LISTENERS" ]]; then
    echo "CLIProxyAPI (port 8317): not listening"
  else
    echo "CLIProxyAPI (port 8317) listeners:"
    printf '  %s\n' "$CLI_LISTENERS"
    if printf '%s\n' "$CLI_LISTENERS" | grep -qE '^(0\.0\.0\.0|\*|\[::\]):'; then
      echo "  [WARN] CLIProxyAPI is reachable on a wildcard address. Management API should be loopback-only."
    fi
  fi
else
  echo "ss utility not found; skipping listener inspection"
fi
echo ""

# 4. Account Manager Health Check Endpoint
echo "--- 4. HEALTH CHECK STATUS ---"
if command -v curl >/dev/null 2>&1; then
  HEALTH_OUT=$(curl -s --max-time 3 "http://127.0.0.1:$DEFAULT_PORT/api/health" 2>/dev/null || echo "Connection refused / failed")
  echo "Local Health Endpoint: $HEALTH_OUT"
  if [[ "$HEALTH_OUT" == *'"status":"healthy"'* ]]; then
    echo "  [OK] Account Manager process responds."
  else
    echo "  [WARN] Account Manager did not report healthy."
    echo "  Action: inspect journalctl -u $DEFAULT_AM_SERVICE and confirm HOST/PORT in manager.env."
  fi
else
  echo "curl not available"
fi
echo ""

# 5. Redacted Configurations
echo "--- 5. CONFIGURATION INTEGRITY (REDACTED) ---"
if [[ -f "$DEFAULT_CONFIG_DIR/manager.env" ]]; then
  echo "Account Manager Config ($DEFAULT_CONFIG_DIR/manager.env):"
  safe_cat_redacted "$DEFAULT_CONFIG_DIR/manager.env"
else
  echo "Account Manager config not present at $DEFAULT_CONFIG_DIR/manager.env"
fi
echo ""

# 6. SSH Tunnel Configuration
echo "--- 6. SSH TUNNEL PERMISSIONS ---"
TUNNEL_AUTH_FILE="/home/$DEFAULT_TUNNEL_USER/.ssh/authorized_keys"
if [[ -f "$TUNNEL_AUTH_FILE" ]]; then
  echo "Tunnel user '$DEFAULT_TUNNEL_USER' authorized_keys entries:"
  safe_cat_redacted "$TUNNEL_AUTH_FILE"
  if grep -E "^command=" "$TUNNEL_AUTH_FILE" | grep -q "no-port-forwarding"; then
    echo "  [WARN] Legacy v1.0.0 restriction found (no-port-forwarding blocks the tunnel)."
    echo "  Action: run 'cliproxy-manager update' to migrate, or re-install with --setup-tunnel-user."
  fi
  if ! grep -q "permitopen=\"127.0.0.1:$DEFAULT_PORT\"" "$TUNNEL_AUTH_FILE" 2>/dev/null; then
    echo "  [INFO] No permitopen restriction for 127.0.0.1:$DEFAULT_PORT found for the tunnel user."
  fi
else
  echo "No authorized_keys found for tunnel user '$DEFAULT_TUNNEL_USER'"
  echo "  Action: run 'sudo ./install.sh --setup-tunnel-user --tunnel-pubkey \"<pubkey>\"'."
fi

echo "Per-user sshd forwarding policy:"
if tunnel_sshd_policy_present "$DEFAULT_TUNNEL_USER"; then
  echo "  [OK] Match User $DEFAULT_TUNNEL_USER policy is present in $SSHD_CONFIG_PATH."
else
  echo "  [INFO] No managed per-user sshd policy found."
  echo "  Action: update or reinstall to add AllowTcpForwarding local / PermitListen none for the tunnel user."
fi

echo ""
echo "=================================================================="
echo "Diagnostics complete. All secrets and keys have been redacted."
echo "=================================================================="
