#!/usr/bin/env bash
# ==============================================================================
# sshd per-user policy installer regression tests (isolated fake sshd)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
source "$PROJECT_ROOT/common/common.sh"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sshd_policy.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
ok() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

cat > "$TEST_ROOT/sshd_ok" <<'EOF'
#!/usr/bin/env bash
# Fake sshd: accept '-t -f FILE' when FILE exists and does not contain INVALID.
if [[ "$1" == "-t" ]]; then
  file="${3:-}"
  [[ -f "$file" ]] || exit 1
  grep -q 'INVALID' "$file" && exit 1
  exit 0
fi
exit 0
EOF
chmod +x "$TEST_ROOT/sshd_ok"

cat > "$TEST_ROOT/sshd_fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TEST_ROOT/sshd_fail"

export SSHD_CONFIG_PATH="$TEST_ROOT/sshd_config"
export SSHD_BIN="$TEST_ROOT/sshd_ok"
export INSTALLER_TEST_MODE=1

# shellcheck source=/dev/null
source "$PROJECT_ROOT/server-installer/lib/installer_core.sh"

cat > "$SSHD_CONFIG_PATH" <<'EOF'
# OpenSSH test configuration
Port 22
PermitRootLogin no
PasswordAuthentication yes

Match User admin
    AllowTcpForwarding yes
EOF
cp "$SSHD_CONFIG_PATH" "$TEST_ROOT/original_config"

echo "=== sshd policy installer ==="
install_tunnel_sshd_policy "amtunnel" "127.0.0.1" 8320 >/dev/null

grep -q "BEGIN cliproxyapi-account-manager tunnel policy" "$SSHD_CONFIG_PATH" && ok "managed block inserted" || bad "managed block missing"
grep -q "Match User amtunnel" "$SSHD_CONFIG_PATH" && ok "policy scoped to tunnel user" || bad "wrong Match User"
grep -q "AllowTcpForwarding local" "$SSHD_CONFIG_PATH" && ok "remote forwarding disabled (AllowTcpForwarding local)" || bad "AllowTcpForwarding local missing"
grep -q "AllowStreamLocalForwarding no" "$SSHD_CONFIG_PATH" && ok "StreamLocal forwarding disabled" || bad "StreamLocal policy missing"
grep -q "PermitOpen 127.0.0.1:8320" "$SSHD_CONFIG_PATH" && ok "PermitOpen restricted to Account Manager" || bad "PermitOpen missing"
grep -q "PermitListen none" "$SSHD_CONFIG_PATH" && ok "PermitListen none installed" || bad "PermitListen none missing"
grep -q "ForceCommand /bin/false" "$SSHD_CONFIG_PATH" && ok "forced command installed" || bad "ForceCommand missing"
grep -q "Match User admin" "$SSHD_CONFIG_PATH" && ok "existing admin Match block preserved" || bad "existing admin block lost"
grep -q "PermitRootLogin no" "$SSHD_CONFIG_PATH" && ok "unrelated sshd directives preserved" || bad "unrelated directive lost"
grep -q "PasswordAuthentication yes" "$SSHD_CONFIG_PATH" && ok "global password policy untouched" || bad "global policy changed"
compgen -G "$SSHD_CONFIG_PATH.cliproxyapi.bak.*" >/dev/null && ok "sshd_config backed up" || bad "no sshd_config backup"

HASH1=$(sha256sum "$SSHD_CONFIG_PATH" | awk '{print $1}')
BEFORE_BACKUPS=$(find "$TEST_ROOT" -maxdepth 1 -name 'sshd_config.cliproxyapi.bak.*' | wc -l | tr -d ' ')
install_tunnel_sshd_policy "amtunnel" "127.0.0.1" 8320 >/dev/null
AFTER_BACKUPS=$(find "$TEST_ROOT" -maxdepth 1 -name 'sshd_config.cliproxyapi.bak.*' | wc -l | tr -d ' ')
[[ "$HASH1" == "$(sha256sum "$SSHD_CONFIG_PATH" | awk '{print $1}')" ]] && ok "policy install is idempotent" || bad "second install changed config"
[[ "$BEFORE_BACKUPS" == "$AFTER_BACKUPS" ]] && ok "idempotent run creates no extra backup" || bad "second install created a backup"

echo "=== failure handling ==="
cp "$SSHD_CONFIG_PATH" "$TEST_ROOT/config_before_failure"
SSHD_BIN="$TEST_ROOT/sshd_fail" install_tunnel_sshd_policy "amtunnel" "127.0.0.1" 8320 >/dev/null 2>&1 || true
cmp -s "$SSHD_CONFIG_PATH" "$TEST_ROOT/config_before_failure" && ok "validation failure leaves previous config active" || bad "validation failure modified config"

cp "$TEST_ROOT/original_config" "$TEST_ROOT/config_unsafe"
SSHD_CONFIG_PATH="$TEST_ROOT/config_unsafe" install_tunnel_sshd_policy 'bad;user' "127.0.0.1" 8320 >/dev/null 2>&1 || true
cmp -s "$TEST_ROOT/config_unsafe" "$TEST_ROOT/original_config" && ok "unsafe username rejected without writes" || bad "unsafe username altered config"

echo "--------------------------------------------------------"
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
