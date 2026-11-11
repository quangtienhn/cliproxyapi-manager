#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Core Management Library
# ==============================================================================

LIB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(cd "$LIB_SCRIPT_DIR/../../common" 2>/dev/null && pwd || echo "$LIB_SCRIPT_DIR/../common")"

if [[ -f "$COMMON_DIR/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "$COMMON_DIR/common.sh"
fi

DEFAULT_APP_DIR="${DEFAULT_APP_DIR:-/opt/cliproxyapi-account-manager}"
DEFAULT_CONFIG_DIR="${DEFAULT_CONFIG_DIR:-/etc/cliproxyapi-account-manager}"
DEFAULT_LOG_DIR="${DEFAULT_LOG_DIR:-/var/log/cliproxyapi-account-manager}"
DEFAULT_DATA_DIR="${DEFAULT_DATA_DIR:-/var/lib/cliproxyapi-account-manager}"
DEFAULT_BACKUP_ROOT="${DEFAULT_BACKUP_ROOT:-/var/backups/cliproxyapi-account-manager}"
DEFAULT_CLIPROXY_CONFIG="${DEFAULT_CLIPROXY_CONFIG:-/etc/cliproxyapi/config.yaml}"
DEFAULT_AUTH_DIR="${DEFAULT_AUTH_DIR:-/var/lib/cliproxyapi/auths}"
DEFAULT_AM_SERVICE="${DEFAULT_AM_SERVICE:-cliproxyapi-account-manager}"
DEFAULT_CLIPROXY_SERVICE="${DEFAULT_CLIPROXY_SERVICE:-cliproxyapi}"
DEFAULT_PORT="${DEFAULT_PORT:-8320}"
DEFAULT_TUNNEL_USER="${DEFAULT_TUNNEL_USER:-amtunnel}"

# Generate secure random secret string
generate_random_secret() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$((len / 2))"
  elif [[ -r /dev/urandom ]]; then
    head -c "$((len * 2))" /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$len"
  else
    date +%s%N | sha256sum | head -c "$len"
  fi
}

# Generate restricted SSH authorized_keys line
# Enforces: no shell, no PTY, no agent/X11 forward, restricted permitopen to loopback target
generate_restricted_authorized_key_entry() {
  local pubkey="$1"
  local target_host="${2:-127.0.0.1}"
  local target_port="${3:-8320}"

  # Sanitize pubkey
  local clean_key
  clean_key=$(echo "$pubkey" | tr -d '\r\n')
  
  if [[ -z "$clean_key" ]]; then
    echo "[ERROR] Public key cannot be empty" >&2
    return 1
  fi

  echo "command=\"/bin/false\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen=\"${target_host}:${target_port}\" ${clean_key}"
}

# Verify system prerequisites
check_prerequisites() {
  local arch
  arch=$(detect_architecture)
  if [[ "$arch" != "amd64" && "$arch" != "arm64" ]]; then
    log_err "Unsupported CPU architecture: $arch. Supported: amd64, arm64."
    return 1
  fi

  if ! command -v node >/dev/null 2>&1; then
    log_err "Node.js is not installed. Node.js 18+ is required."
    return 1
  fi

  local node_major
  node_major=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
  if [[ "$node_major" -lt 18 ]]; then
    log_err "Node.js version is $node_major. Node.js 18+ is required."
    return 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not found. Non-systemd system detected."
  fi

  log_ok "Prerequisites satisfied: Architecture=$arch, Node.js=$(node -v)"
  return 0
}

# Redact sensitive fields in files for diagnostic reporting
safe_cat_redacted() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "[File not found: $file]"
    return 0
  fi
  redact_sensitive < "$file"
}
