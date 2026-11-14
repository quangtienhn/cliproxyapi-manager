#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Core Management Library
# ==============================================================================
# shellcheck shell=bash

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
DEFAULT_LOOPBACK_HOST="${DEFAULT_LOOPBACK_HOST:-127.0.0.1}"

# SSH public key types accepted by the installer.
KEY_TYPE_RE='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)'

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

# Extract the base64 key blob from an authorized_keys style public key line.
extract_pubkey_blob() {
  printf '%s\n' "$1" | awk -v re="^${KEY_TYPE_RE}$" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ re) { print $(i + 1); exit }
      }
    }'
}

# Extract "<type> <base64> [comment]" from an authorized_keys line, dropping options.
extract_pubkey_material() {
  printf '%s\n' "$1" | awk -v re="^${KEY_TYPE_RE}$" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ re) {
          for (j = i; j <= NF; j++) printf "%s%s", $j, (j == NF ? "\n" : " ")
          exit
        }
      }
    }'
}

# Generate a restricted SSH authorized_keys line.
#
# Restrictions:
#   command="/bin/false"  - no shell or remote command execution
#   no-agent-forwarding   - no SSH agent forwarding
#   no-pty                - no TTY allocation
#   no-user-rc            - no ~/.ssh/rc execution
#   no-X11-forwarding     - no X11 forwarding
#   permitopen            - only TCP local forwarding to the Account Manager
#   permitlisten          - defense-in-depth cap on remote forwarding (loopback:1)
#
# Remote forwarding is *disabled completely* by the per-user sshd policy that
# the installer writes (AllowTcpForwarding local + PermitListen none). The
# permitlisten key option above is a second, independent boundary for the case
# where an administrator deliberately removes the server-side policy.
generate_restricted_authorized_key_entry() {
  local pubkey="$1"
  local target_host="${2:-$DEFAULT_LOOPBACK_HOST}"
  local target_port="${3:-$DEFAULT_PORT}"

  local clean_key
  clean_key=$(printf '%s' "$pubkey" | tr -d '\r\n')

  if [[ -z "$clean_key" ]]; then
    log_err "Public key cannot be empty"
    return 1
  fi

  if ! printf '%s\n' "$clean_key" | grep -qE "^${KEY_TYPE_RE} [A-Za-z0-9+/=]+( .*)?$"; then
    log_err "Public key is not a valid OpenSSH public key line"
    return 1
  fi

  if ! [[ "$target_host" =~ ^[A-Za-z0-9._:-]+$ ]] || ! [[ "$target_port" =~ ^[0-9]+$ ]]; then
    log_err "Invalid permitopen target: ${target_host}:${target_port}"
    return 1
  fi

  printf 'command="/bin/false",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="%s:%s",permitlisten="127.0.0.1:1" %s\n' \
    "$target_host" "$target_port" "$clean_key"
}

# Append the restricted key to an existing authorized_keys file without
# destroying unrelated administrator or third-party keys.
append_restricted_authorized_key() {
  local auth_file="$1"
  local pubkey="$2"
  local target_host="${3:-$DEFAULT_LOOPBACK_HOST}"
  local target_port="${4:-$DEFAULT_PORT}"

  local entry
  entry=$(generate_restricted_authorized_key_entry "$pubkey" "$target_host" "$target_port") || return 1

  local key_blob
  key_blob=$(extract_pubkey_blob "$pubkey")
  if [[ -z "$key_blob" ]]; then
    log_err "Unable to extract key material from the supplied public key"
    return 1
  fi

  local auth_dir
  auth_dir=$(dirname "$auth_file")
  mkdir -p "$auth_dir"
  chmod 0700 "$auth_dir" 2>/dev/null || true

  if [[ ! -e "$auth_file" ]]; then
    : > "$auth_file"
  fi
  chmod 0600 "$auth_file" 2>/dev/null || true

  if grep -qF "$key_blob" "$auth_file" 2>/dev/null; then
    log_info "Tunnel public key already present in $auth_file; leaving file unchanged."
    return 0
  fi

  # Keep the file newline-terminated so unrelated entries are not merged.
  if [[ -s "$auth_file" ]]; then
    local last_byte
    last_byte=$(tail -c 1 "$auth_file" | od -An -t x1 | tr -d ' \n')
    if [[ "$last_byte" != "0a" ]]; then
      printf '\n' >> "$auth_file"
    fi
  fi

  printf '%s\n' "$entry" >> "$auth_file"
  chmod 0600 "$auth_file" 2>/dev/null || true
  log_ok "Restricted tunnel key appended to $auth_file (existing keys preserved)."
}

# Returns 0 when the supplied authorized_keys line is a legacy v1.0.0 tunnel key
# for the given target: it has permitopen=<host:port> and no-port-forwarding.
is_legacy_tunnel_key_line() {
  local line="$1"
  local target_host="$2"
  local target_port="$3"

  [[ "$line" == *"permitopen=\"${target_host}:${target_port}\""* ]] || return 1
  [[ "$line" == *"no-port-forwarding"* ]] || return 1
  printf '%s\n' "$line" | grep -qE " (${KEY_TYPE_RE}) " || return 1
  return 0
}

# Safely migrate legacy v1.0.0 tunnel keys to the hardened restriction.
#
# Guarantees:
#   - unrelated keys, comments and blank lines are preserved verbatim
#   - a timestamped backup is created before any write
#   - the original file is left untouched if any line cannot be migrated
#   - idempotent: a second run makes no changes and creates no backup
#   - ownership and mode of the original file are preserved where possible
migrate_authorized_keys_file() {
  local auth_file="$1"
  local target_host="${2:-$DEFAULT_LOOPBACK_HOST}"
  local target_port="${3:-$DEFAULT_PORT}"

  if [[ ! -f "$auth_file" ]]; then
    return 0
  fi

  # Fast path: nothing to migrate, no backup written.
  local found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_legacy_tunnel_key_line "$line" "$target_host" "$target_port"; then
      found=1
      break
    fi
  done < "$auth_file"
  if [[ "$found" -eq 0 ]]; then
    return 0
  fi

  local backup_file
  backup_file="${auth_file}.bak.$(date +%Y%m%dT%H%M%S)"
  if ! cp -a "$auth_file" "$backup_file"; then
    log_err "Unable to back up $auth_file; refusing to migrate."
    return 1
  fi
  chmod 0600 "$backup_file" 2>/dev/null || true

  local tmp_file
  tmp_file="${auth_file}.tmp.$$"
  : > "$tmp_file"
  chmod 0600 "$tmp_file" 2>/dev/null || true

  local changed=0
  local failed=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if is_legacy_tunnel_key_line "$line" "$target_host" "$target_port"; then
      local pub_material entry
      pub_material=$(extract_pubkey_material "$line")
      if [[ -n "$pub_material" ]] && entry=$(generate_restricted_authorized_key_entry "$pub_material" "$target_host" "$target_port"); then
        printf '%s\n' "$entry" >> "$tmp_file"
        changed=1
      else
        printf '%s\n' "$line" >> "$tmp_file"
        failed=1
      fi
    else
      printf '%s\n' "$line" >> "$tmp_file"
    fi
  done < "$auth_file"

  if [[ "$failed" -ne 0 ]]; then
    rm -f "$tmp_file"
    log_err "Migration aborted: one or more tunnel keys could not be parsed. Original file left unchanged."
    return 1
  fi

  if [[ "$changed" -eq 0 ]]; then
    rm -f "$tmp_file"
    return 0
  fi

  if ! mv "$tmp_file" "$auth_file"; then
    rm -f "$tmp_file"
    log_err "Failed to replace $auth_file; original file left unchanged."
    return 1
  fi
  chmod 0600 "$auth_file" 2>/dev/null || true
  if [[ "${INSTALLER_TEST_MODE:-0}" != "1" && "$(id -u)" -eq 0 ]]; then
    chown --reference="$backup_file" "$auth_file" 2>/dev/null || true
  fi

  log_ok "Migrated legacy v1.0.0 tunnel restrictions in $auth_file (backup: $backup_file)"
  return 0
}

# Remove product-managed restricted keys for a given target while preserving
# every unrelated line. Used only by an explicit uninstall purge.
remove_restricted_authorized_keys() {
  local auth_file="$1"
  local target_host="${2:-$DEFAULT_LOOPBACK_HOST}"
  local target_port="${3:-$DEFAULT_PORT}"

  [[ -f "$auth_file" ]] || return 0
  local marker="permitopen=\"${target_host}:${target_port}\""
  grep -qF "$marker" "$auth_file" 2>/dev/null || return 0

  local backup_file
  backup_file="${auth_file}.bak.$(date +%Y%m%dT%H%M%S)"
  cp -a "$auth_file" "$backup_file" || return 1
  chmod 0600 "$backup_file" 2>/dev/null || true

  local tmp_file
  tmp_file="${auth_file}.tmp.$$"
  grep -vF "$marker" "$auth_file" > "$tmp_file" || true
  mv "$tmp_file" "$auth_file" || return 1
  chmod 0600 "$auth_file" 2>/dev/null || true
  log_ok "Removed managed tunnel key from $auth_file (backup: $backup_file)"
}

# Force the Account Manager environment file to loopback-only binding.
# Existing installations created by v1.0.0 may still contain HOST=0.0.0.0.
enforce_loopback_bind() {
  local env_file="${1:-$DEFAULT_CONFIG_DIR/manager.env}"
  local loopback_host="${2:-$DEFAULT_LOOPBACK_HOST}"

  if [[ ! -f "$env_file" ]]; then
    return 0
  fi

  local current=""
  current=$(grep -E '^[[:space:]]*HOST[[:space:]]*=' "$env_file" 2>/dev/null | tail -n 1 | cut -d'=' -f2- | tr -d '"'"'"' \r' || true)
  if [[ "$current" == "$loopback_host" ]]; then
    return 0
  fi

  local backup_file
  backup_file="${env_file}.bak.bind.$(date +%Y%m%dT%H%M%S)"
  if ! cp -a "$env_file" "$backup_file"; then
    log_err "Unable to back up $env_file; refusing to change bind address."
    return 1
  fi
  chmod 0600 "$backup_file" 2>/dev/null || true

  if grep -qE '^[[:space:]]*HOST[[:space:]]*=' "$env_file"; then
    sed -i -E "s|^[[:space:]]*HOST[[:space:]]*=.*|HOST=${loopback_host}|" "$env_file"
  else
    [[ -s "$env_file" ]] && printf '\n' >> "$env_file"
    printf 'HOST=%s\n' "$loopback_host" >> "$env_file"
  fi

  chmod 0640 "$env_file" 2>/dev/null || true
  log_ok "Enforced loopback bind (HOST=${loopback_host}) in $env_file (previous value: ${current:-unset}, backup: $backup_file)"
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

# Optional per-user sshd policy helpers (server-side forwarding lockdown).
if [[ -f "$LIB_SCRIPT_DIR/sshd_policy.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_SCRIPT_DIR/sshd_policy.sh"
fi
