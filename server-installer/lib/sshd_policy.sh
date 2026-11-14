#!/usr/bin/env bash
# ==============================================================================
# CLIProxyAPI Easy Installer - Per-user OpenSSH forwarding policy
# ==============================================================================
# shellcheck shell=bash
#
# Adds a narrowly scoped `Match User <tunnel-user>` block at the end of the
# system sshd_config. Only the dedicated tunnel account is affected.
#
# Safety properties:
#   - the existing sshd_config is backed up before any change
#   - the new configuration is validated with `sshd -t` before activation
#   - a validation failure restores the previous file automatically
#   - a reload failure restores the previous file and reloads again
#   - SSH is reloaded (not restarted); administrators' sessions are unaffected
#   - the managed block is delimited and can be replaced idempotently

SSHD_CONFIG_PATH="${SSHD_CONFIG_PATH:-/etc/ssh/sshd_config}"
SSHD_BIN="${SSHD_BIN:-sshd}"
SSHD_POLICY_BEGIN="# BEGIN cliproxyapi-account-manager tunnel policy"
SSHD_POLICY_END="# END cliproxyapi-account-manager tunnel policy"

# Reload the system SSH service without restarting it.
sshd_policy_reload() {
  if [[ "${INSTALLER_TEST_MODE:-0}" == "1" ]]; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet ssh 2>/dev/null; then
      systemctl reload ssh 2>/dev/null && return 0
    fi
    if systemctl is-active --quiet sshd 2>/dev/null; then
      systemctl reload sshd 2>/dev/null && return 0
    fi
  fi
  log_warn "Could not reload the SSH service automatically. The policy file was validated but may require 'systemctl reload ssh'."
  return 1
}

# Render the managed Match block.
render_tunnel_sshd_policy() {
  local tunnel_user="$1"
  local target_host="${2:-127.0.0.1}"
  local target_port="${3:-8320}"

  cat <<EOF
${SSHD_POLICY_BEGIN}
Match User ${tunnel_user}
    AllowTcpForwarding local
    AllowStreamLocalForwarding no
    PermitOpen ${target_host}:${target_port}
    PermitListen none
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForceCommand /bin/false
${SSHD_POLICY_END}
EOF
}

# Remove a previously installed managed block from stdin.
strip_tunnel_sshd_policy() {
  awk -v begin="$SSHD_POLICY_BEGIN" -v end="$SSHD_POLICY_END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  '
}

validate_tunnel_user() {
  local user="$1"
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
    log_err "Refusing to write sshd policy for unsafe username: '$user'"
    return 1
  fi
  return 0
}

# Install or refresh the per-user policy. Returns 0 on success, 1 on failure
# (in which case the previous sshd_config remains active).
install_tunnel_sshd_policy() {
  local tunnel_user="${1:-$DEFAULT_TUNNEL_USER}"
  local target_host="${2:-127.0.0.1}"
  local target_port="${3:-$DEFAULT_PORT}"

  validate_tunnel_user "$tunnel_user" || return 1

  if [[ ! -f "$SSHD_CONFIG_PATH" ]]; then
    log_warn "sshd_config not found at $SSHD_CONFIG_PATH; skipping per-user SSH policy."
    return 1
  fi

  if ! command -v "$SSHD_BIN" >/dev/null 2>&1; then
    log_warn "sshd binary not found; cannot validate SSH policy. Skipping."
    return 1
  fi

  local backup_file
  backup_file="${SSHD_CONFIG_PATH}.cliproxyapi.bak.$(date +%Y%m%dT%H%M%S)"
  if ! cp -a "$SSHD_CONFIG_PATH" "$backup_file"; then
    log_err "Unable to back up $SSHD_CONFIG_PATH; refusing to modify SSH configuration."
    return 1
  fi
  chmod 0600 "$backup_file" 2>/dev/null || true

  local tmp_file
  tmp_file="$(dirname "$SSHD_CONFIG_PATH")/.sshd_config.cliproxyapi.$$"
  strip_tunnel_sshd_policy < "$SSHD_CONFIG_PATH" > "$tmp_file"
  render_tunnel_sshd_policy "$tunnel_user" "$target_host" "$target_port" >> "$tmp_file"

  # No-op when the managed policy is already exactly what we would write.
  if cmp -s "$tmp_file" "$SSHD_CONFIG_PATH"; then
    rm -f "$tmp_file"
    rm -f "$backup_file"
    log_ok "Per-user SSH forwarding policy already current for '$tunnel_user'."
    return 0
  fi

  # Validate before replacing the live file.
  if ! "$SSHD_BIN" -t -f "$tmp_file" >/dev/null 2>&1; then
    log_err "Generated sshd policy failed validation. Existing SSH configuration was not changed."
    rm -f "$tmp_file"
    return 1
  fi

  chmod 0644 "$tmp_file" 2>/dev/null || true
  if ! mv "$tmp_file" "$SSHD_CONFIG_PATH"; then
    rm -f "$tmp_file"
    log_err "Unable to replace sshd_config; existing configuration was not changed."
    return 1
  fi
  if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
    chown root:root "$SSHD_CONFIG_PATH" 2>/dev/null || true
  fi

  # Re-validate the installed file (covers include path resolution differences).
  if ! "$SSHD_BIN" -t -f "$SSHD_CONFIG_PATH" >/dev/null 2>&1; then
    log_err "Installed sshd_config failed validation. Rolling back."
    cp -a "$backup_file" "$SSHD_CONFIG_PATH"
    return 1
  fi

  if ! sshd_policy_reload; then
    log_err "SSH reload failed. Rolling back to the previous configuration."
    cp -a "$backup_file" "$SSHD_CONFIG_PATH"
    "$SSHD_BIN" -t -f "$SSHD_CONFIG_PATH" >/dev/null 2>&1 || true
    sshd_policy_reload || true
    return 1
  fi

  log_ok "Per-user SSH forwarding policy installed for '$tunnel_user' (backup: $backup_file)"
  return 0
}

# Remove the managed block, validating the result before activation. This is
# used by `uninstall.sh --purge-data` to leave no product-managed SSH policy
# behind. Unrelated Match blocks and global directives are preserved.
remove_tunnel_sshd_policy() {
  if [[ ! -f "$SSHD_CONFIG_PATH" ]]; then
    return 0
  fi
  if ! grep -qF "$SSHD_POLICY_BEGIN" "$SSHD_CONFIG_PATH" 2>/dev/null; then
    log_info "No managed SSH forwarding policy present; nothing to remove."
    return 0
  fi
  if ! command -v "$SSHD_BIN" >/dev/null 2>&1; then
    log_warn "sshd binary not found; cannot safely remove the SSH policy."
    return 1
  fi

  local backup_file
  backup_file="${SSHD_CONFIG_PATH}.cliproxyapi.bak.$(date +%Y%m%dT%H%M%S)"
  cp -a "$SSHD_CONFIG_PATH" "$backup_file" || return 1
  chmod 0600 "$backup_file" 2>/dev/null || true

  local tmp_file
  tmp_file="$(dirname "$SSHD_CONFIG_PATH")/.sshd_config.cliproxyapi.$$"
  strip_tunnel_sshd_policy < "$SSHD_CONFIG_PATH" > "$tmp_file"
  if ! "$SSHD_BIN" -t -f "$tmp_file" >/dev/null 2>&1; then
    log_err "Removing the SSH policy would produce an invalid configuration; leaving it in place."
    rm -f "$tmp_file"
    return 1
  fi
  mv "$tmp_file" "$SSHD_CONFIG_PATH" || return 1
  if [[ "${INSTALLER_TEST_MODE:-0}" != "1" ]]; then
    chown root:root "$SSHD_CONFIG_PATH" 2>/dev/null || true
  fi
  if ! sshd_policy_reload; then
    log_warn "SSH configuration changed but the service could not be reloaded automatically."
    return 1
  fi
  log_ok "Removed managed SSH forwarding policy (backup: $backup_file)"
}

# Returns 0 when the managed policy block is present for the given user.
tunnel_sshd_policy_present() {
  local tunnel_user="${1:-$DEFAULT_TUNNEL_USER}"
  [[ -f "$SSHD_CONFIG_PATH" ]] || return 1
  grep -qF "$SSHD_POLICY_BEGIN" "$SSHD_CONFIG_PATH" 2>/dev/null || return 1
  grep -qE "^[[:space:]]*Match User ${tunnel_user}\$" "$SSHD_CONFIG_PATH" 2>/dev/null || return 1
  return 0
}
