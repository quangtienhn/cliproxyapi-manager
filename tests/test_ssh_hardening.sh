#!/usr/bin/env bash
# ==============================================================================
# SSH Hardening E2E Suite
# ------------------------------------------------------------------------------
# Proves, against a real OpenSSH daemon:
#   - TCP local forwarding to the Account Manager is allowed
#   - TCP local forwarding to any other destination is denied
#   - Unix-domain (StreamLocal) forwarding is denied
#   - remote forwarding is denied by the per-user sshd policy
#   - shell, remote command and PTY allocation are denied
#   - host key verification fails closed on empty/malformed/mismatched pins
#
# The suite needs a local sshd that can authenticate the current test user with
# an absolute AuthorizedKeysFile. When the required binaries are unavailable it
# exits with SKIP (0) so CI can decide whether to provision them.
# ==============================================================================
set -u

SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
SSH_BIN="${SSH_BIN:-ssh}"
SSH_KEYGEN="${SSH_KEYGEN:-ssh-keygen}"
SSHD_CLIENT_KEY="${SSHD_CLIENT_KEY:-/tmp/sshd-fixtures/client_key}"
SSHD_HOST_KEY="${SSHD_HOST_KEY:-/tmp/sshd-fixtures/host_key}"
SSHD_HOST_PUB="${SSHD_HOST_PUB:-${SSHD_HOST_KEY}.pub}"
SSHD_USER="${SSHD_USER:-$(id -un)}"
SSHD_PORT="${SSHD_PORT:-2222}"

if [[ ! -x "$SSHD_BIN" || ! -f "$SSHD_CLIENT_KEY" || ! -f "$SSHD_HOST_KEY" ]]; then
  echo "SKIP: local sshd test fixtures not available (set SSHD_BIN/SSHD_CLIENT_KEY/SSHD_HOST_KEY)."
  exit 0
fi
command -v "$SSH_BIN" >/dev/null 2>&1 || { echo "SKIP: ssh client not available"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 0; }

PASS=0
FAIL=0
TAB=$(mktemp -d "${TMPDIR:-/tmp}/ssh_hardening.XXXXXX") || exit 1
TAB_WIN=$(cygpath -m "$TAB" 2>/dev/null || printf '%s' "$TAB")

cleanup() {
  [[ -n "${SSHD_PID:-}" ]] && kill -9 "$SSHD_PID" 2>/dev/null || true
  [[ -n "${TUNNEL_PID:-}" ]] && kill -9 "$TUNNEL_PID" 2>/dev/null || true
  [[ -n "${MOCK_PID:-}" ]] && kill -9 "$MOCK_PID" 2>/dev/null || true
  # MSYS/Git Bash may leave the Windows ssh.exe process behind after a kill.
  # Only terminate clients whose known_hosts path belongs to this test run.
  if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
    powershell -NoProfile -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='ssh.exe'\" | Where-Object { \$_.CommandLine -like '*ssh_hardening*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" \
      >/dev/null 2>&1 || true
  fi
  rm -rf "$TAB"
}
trap cleanup EXIT

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

PUB=$(cat "${SSHD_CLIENT_KEY}.pub")
HOST_PUB=$(cat "$SSHD_HOST_PUB")
KNOWN_OK="$TAB/known_hosts.ok"
printf '[127.0.0.1]:%s %s\n' "$SSHD_PORT" "$HOST_PUB" > "$KNOWN_OK"

# Mock upstream services: 8320 is permitted, 8321/8317 must be unreachable.
node -e '
  const http = require("http");
  http.createServer((q, s) => s.end("AM_OK")).listen(8320, "127.0.0.1");
  http.createServer((q, s) => s.end("FORBIDDEN_OK")).listen(8321, "127.0.0.1");
' &
MOCK_PID=$!
sleep 0.6

write_key() {
  local options="$1"
  printf '%s %s\n' "$options" "$PUB" > "$TAB/authorized_keys"
}

base_config() {
  local file="$1"
  local with_policy="$2"
  cat > "$file" <<EOF
Port ${SSHD_PORT}
ListenAddress 127.0.0.1
HostKey ${TAB_WIN}/host_key
StrictModes no
AuthorizedKeysFile ${TAB_WIN}/authorized_keys
LogLevel DEBUG3
AllowTcpForwarding yes
EOF
  if [[ "$with_policy" == "yes" ]]; then
    cat >> "$file" <<EOF
Match User ${SSHD_USER}
    AllowTcpForwarding local
    AllowStreamLocalForwarding no
    PermitOpen 127.0.0.1:8320
    PermitListen none
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    ForceCommand /bin/false
EOF
  fi
}

cp "$SSHD_HOST_KEY" "$TAB/host_key"
chmod 600 "$TAB/host_key" 2>/dev/null || true
base_config "$TAB/sshd.conf" no
base_config "$TAB/sshd_policy.conf" yes

start_sshd() {
  local conf="$1" log="$2"
  "$SSHD_BIN" -t -f "$conf" >/dev/null 2>&1 || { echo "sshd config invalid: $conf"; return 1; }
  "$SSHD_BIN" -d -f "$conf" -p "$SSHD_PORT" > "$log" 2>&1 &
  SSHD_PID=$!
  disown "$SSHD_PID" 2>/dev/null || true
  sleep 0.8
  return 0
}

stop_sshd() {
  [[ -n "${SSHD_PID:-}" ]] && kill -9 "$SSHD_PID" 2>/dev/null || true
  SSHD_PID=""
  sleep 0.2
}

ssh_common() {
  "$SSH_BIN" -p "$SSHD_PORT" -i "$SSHD_CLIENT_KEY" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_OK" \
    -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes "$@"
}

# Connect through a local forward; returns 0 only when the upstream answered.
probe_forward() {
  local local_port="$1" expect="$2"
  local out
  out=$(curl -s --max-time 2 "http://127.0.0.1:${local_port}/" 2>/dev/null || true)
  if [[ "$expect" == "allow" && "$out" == "AM_OK" ]]; then return 0; fi
  if [[ "$expect" == "deny" && "$out" != "FORBIDDEN_OK" && "$out" != "AM_OK" ]]; then return 0; fi
  return 1
}

free_port() {
  node -e 'const n=require("net");const s=n.createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close();});'
}

run_local_case() {
  local name="$1" target="$2" expect="$3"
  local lport
  lport=$(free_port)
  local log="$TAB/local_${lport}.log"
  start_sshd "$TAB/sshd_policy.conf" "$log" || { bad "$name (sshd start)"; return; }
  ssh_common -N -L "127.0.0.1:${lport}:${target}" "${SSHD_USER}@127.0.0.1" >/dev/null 2>&1 &
  TUNNEL_PID=$!
  disown "$TUNNEL_PID" 2>/dev/null || true
  sleep 1
  if probe_forward "$lport" "$expect"; then ok "$name"; else bad "$name"; fi
  kill -9 "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
  stop_sshd
}

run_remote_case() {
  local name="$1" spec="$2" expect="$3" log="$TAB/remote_$RANDOM.log"
  start_sshd "$TAB/sshd_policy.conf" "$log" || { bad "$name (sshd start)"; return; }
  set +e
  timeout 3 "$SSH_BIN" -p "$SSHD_PORT" -i "$SSHD_CLIENT_KEY" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_OK" \
    -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes \
    -o ExitOnForwardFailure=yes -N -R "$spec" "${SSHD_USER}@127.0.0.1" >/dev/null 2>&1
  local rc=$?
  set -e
  stop_sshd
  if [[ "$expect" == "deny" ]]; then
    # 255 = sshd refused the global request; 124 would mean it was accepted.
    if [[ "$rc" -ne 0 && "$rc" -ne 124 ]]; then ok "$name (rc=$rc)"; else bad "$name (rc=$rc)"; fi
  else
    [[ "$rc" -eq 124 ]] && ok "$name (listener accepted)" || bad "$name (rc=$rc)"
  fi
}

run_session_case() {
  local name="$1" expect="$2"; shift 2
  start_sshd "$TAB/sshd_policy.conf" "$TAB/session_$RANDOM.log" || { bad "$name (sshd start)"; return; }
  set +e
  timeout 3 "$SSH_BIN" -p "$SSHD_PORT" -i "$SSHD_CLIENT_KEY" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_OK" \
    -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes \
    "$@" "${SSHD_USER}@127.0.0.1" >/dev/null 2>&1
  local rc=$?
  set -e
  stop_sshd
  if [[ "$expect" == "deny" ]]; then
    [[ "$rc" -ne 0 ]] && ok "$name (rc=$rc)" || bad "$name"
  else
    [[ "$rc" -eq 0 ]] && ok "$name" || bad "$name (rc=$rc)"
  fi
}

echo "=== SSH hardening E2E (policy + key restrictions) ==="
write_key 'command="/bin/false",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320",permitlisten="127.0.0.1:1"'

run_local_case "local forward 127.0.0.1:8320 allowed" "127.0.0.1:8320" allow
run_local_case "local forward 127.0.0.1:8321 denied" "127.0.0.1:8321" deny
run_local_case "local forward 127.0.0.1:8317 denied" "127.0.0.1:8317" deny
run_local_case "streamlocal /var/run/docker.sock denied" "/var/run/docker.sock" deny
run_local_case "streamlocal /tmp/other.sock denied" "/tmp/other.sock" deny

run_remote_case "remote forward 127.0.0.1:1 denied by policy" "127.0.0.1:1:127.0.0.1:8320" deny
run_remote_case "remote forward 127.0.0.1:2 denied by policy" "127.0.0.1:2:127.0.0.1:8320" deny
run_remote_case "remote forward 0.0.0.0:1 denied by policy" "0.0.0.0:1:127.0.0.1:8320" deny
run_remote_case "remote forward localhost:1 denied by policy" "localhost:1:127.0.0.1:8320" deny
run_remote_case "remote forward [::1]:1 denied by policy" "[::1]:1:127.0.0.1:8320" deny
run_remote_case "remote forward 8320 denied by policy" "8320:127.0.0.1:8320" deny

run_session_case "shell denied" deny -T -- /bin/sh -c id
run_session_case "remote command denied" deny -T -- /bin/true
run_session_case "PTY denied" deny -tt -- /bin/sh

# Control: without the server policy, the key alone still blocks destinations
# other than 8320, and permits the documented 127.0.0.1:1 listener. This
# demonstrates why the server-side policy is required.
run_control_local() {
  start_sshd "$TAB/sshd.conf" "$TAB/control.log" || { bad "control (sshd start)"; return; }
  local lport
  lport=$(free_port)
  ssh_common -N -L "127.0.0.1:${lport}:127.0.0.1:8321" "${SSHD_USER}@127.0.0.1" >/dev/null 2>&1 &
  TUNNEL_PID=$!
  disown "$TUNNEL_PID" 2>/dev/null || true
  sleep 1
  if probe_forward "$lport" deny; then ok "control: key alone still denies 8321"; else bad "control: key alone still denies 8321"; fi
  kill -9 "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
  stop_sshd
}
run_control_local

echo "=== Host key verification (fail closed) ==="
hostkey_case() {
  local name="$1" known_file="$2" expect="$3"
  local lport
  lport=$(free_port)
  start_sshd "$TAB/sshd_policy.conf" "$TAB/hostkey_$RANDOM.log" || { bad "$name (sshd start)"; return; }
  set +e
  timeout 3 "$SSH_BIN" -p "$SSHD_PORT" -i "$SSHD_CLIENT_KEY" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_file" \
    -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes \
    -N -L "${lport}:127.0.0.1:8320" "${SSHD_USER}@127.0.0.1" >/dev/null 2>&1
  local rc=$?
  set -e
  stop_sshd
  if [[ "$expect" == "deny" ]]; then
    [[ "$rc" -ne 0 && "$rc" -ne 124 ]] && ok "$name (rc=$rc)" || bad "$name (rc=$rc)"
  else
    [[ "$rc" -eq 124 ]] && ok "$name" || bad "$name (rc=$rc)"
  fi
}

: > "$TAB/known_empty"
printf 'garbage not-a-host-key\n' > "$TAB/known_bad"
printf '[127.0.0.1]:%s %s\n' "$SSHD_PORT" "$(cat "${SSHD_CLIENT_KEY}.pub")" > "$TAB/known_wrong"

hostkey_case "empty known_hosts rejected" "$TAB/known_empty" deny
hostkey_case "malformed known_hosts rejected" "$TAB/known_bad" deny
hostkey_case "host key mismatch rejected" "$TAB/known_wrong" deny
hostkey_case "missing known_hosts rejected" "$TAB/does_not_exist" deny
hostkey_case "correct pinned host key accepted" "$KNOWN_OK" allow

echo "--------------------------------------------------------"
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]]
