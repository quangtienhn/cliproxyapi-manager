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
  echo "Checking port $DEFAULT_PORT listeners (Account Manager):"
  ss -tulpn 2>/dev/null | grep -E ":$DEFAULT_PORT\b" || echo "Port $DEFAULT_PORT is not bound or not accessible"
  echo "Checking port 8317 listeners (CLIProxyAPI):"
  ss -tulpn 2>/dev/null | grep -E ":8317\b" || echo "Port 8317 is not bound or not accessible"
else
  echo "ss utility not found"
fi
echo ""

# 4. Account Manager Health Check Endpoint
echo "--- 4. HEALTH CHECK STATUS ---"
if command -v curl >/dev/null 2>&1; then
  HEALTH_OUT=$(curl -s "http://127.0.0.1:$DEFAULT_PORT/api/health" 2>/dev/null || echo "Connection refused / failed")
  echo "Local Health Endpoint: $HEALTH_OUT"
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
else
  echo "No authorized_keys found for tunnel user '$DEFAULT_TUNNEL_USER'"
fi

echo ""
echo "=================================================================="
echo "Diagnostics complete. All secrets and keys have been redacted."
echo "=================================================================="
