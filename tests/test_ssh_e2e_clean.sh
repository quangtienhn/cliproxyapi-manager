#!/usr/bin/env bash
# ==============================================================================
# OpenSSH Tunnel E2E Integration Suite
# ==============================================================================
set -u

PUBKEY=$(cat /c/Users/a/AppData/Local/Temp/test_sshd/client_key.pub)
PASS=0
FAIL=0

# Start mock HTTP backend on 127.0.0.1:8320 and 8321
node -e '
  const http = require("http");
  http.createServer((req, res) => res.end("MOCK_ACCOUNT_MANAGER_8320")).listen(8320, "127.0.0.1");
  http.createServer((req, res) => res.end("MOCK_FORBIDDEN_8321")).listen(8321, "127.0.0.1");
' &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
sleep 0.5

# Test 1: Legitimate Local Forwarding to 127.0.0.1:8320
echo "command=\"/bin/false\",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen=\"127.0.0.1:8320\",permitlisten=\"127.0.0.1:1\" $PUBKEY" > /c/Users/a/AppData/Local/Temp/test_sshd/authorized_keys

/c/Users/a/AppData/Local/Temp/openssh_portable/OpenSSH-Win64/sshd.exe \
  -d \
  -f C:/Users/a/AppData/Local/Temp/test_sshd/sshd_config \
  -p 2222 > /c/Users/a/AppData/Local/Temp/test_sshd/sshd1.log 2>&1 &
SSHD_PID=$!
sleep 1

ssh -p 2222 -i /c/Users/a/AppData/Local/Temp/test_sshd/client_key \
  -o StrictHostKeyChecking=no -o ConnectTimeout=2 -o ExitOnForwardFailure=yes \
  -N -L 18320:127.0.0.1:8320 a@127.0.0.1 >/dev/null 2>&1 &
TUNNEL_PID=$!
sleep 1

RESP=$(curl -s --max-time 2 http://127.0.0.1:18320 || echo "FAIL")
kill $TUNNEL_PID 2>/dev/null || true
wait $SSHD_PID 2>/dev/null || kill $SSHD_PID 2>/dev/null || true

if [[ "$RESP" == "MOCK_ACCOUNT_MANAGER_8320" ]]; then
  echo "  [PASS] Test 1: Local port forwarding to 127.0.0.1:8320 succeeded."
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Test 1: Local port forwarding failed! Response: $RESP"
  FAIL=$((FAIL + 1))
fi

# Test 2: Forbidden Port 8321 Blocked
/c/Users/a/AppData/Local/Temp/openssh_portable/OpenSSH-Win64/sshd.exe \
  -d \
  -f C:/Users/a/AppData/Local/Temp/test_sshd/sshd_config \
  -p 2222 > /c/Users/a/AppData/Local/Temp/test_sshd/sshd2.log 2>&1 &
SSHD_PID=$!
sleep 1

ssh -p 2222 -i /c/Users/a/AppData/Local/Temp/test_sshd/client_key \
  -o StrictHostKeyChecking=no -o ConnectTimeout=2 -o ExitOnForwardFailure=yes \
  -N -L 18321:127.0.0.1:8321 a@127.0.0.1 >/dev/null 2>&1 &
TUNNEL_PID=$!
sleep 1

RESP2=$(curl -s --max-time 2 http://127.0.0.1:18321 || echo "CURL_FAILED")
kill $TUNNEL_PID 2>/dev/null || true
wait $SSHD_PID 2>/dev/null || kill $SSHD_PID 2>/dev/null || true

if [[ "$RESP2" == "CURL_FAILED" ]]; then
  echo "  [PASS] Test 2: Port forwarding to forbidden port 8321 successfully blocked."
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Test 2: Forbidden port was reached!"
  FAIL=$((FAIL + 1))
fi

# Test 3: Remote command execution blocked
/c/Users/a/AppData/Local/Temp/openssh_portable/OpenSSH-Win64/sshd.exe \
  -d \
  -f C:/Users/a/AppData/Local/Temp/test_sshd/sshd_config \
  -p 2222 > /c/Users/a/AppData/Local/Temp/test_sshd/sshd3.log 2>&1 &
SSHD_PID=$!
sleep 1

set +e
ssh -p 2222 -i /c/Users/a/AppData/Local/Temp/test_sshd/client_key \
  -o StrictHostKeyChecking=no a@127.0.0.1 whoami >/dev/null 2>&1
CMD_RC=$?
set -e
wait $SSHD_PID 2>/dev/null || kill $SSHD_PID 2>/dev/null || true

if [[ "$CMD_RC" -ne 0 ]]; then
  echo "  [PASS] Test 3: Remote command execution rejected (exit code $CMD_RC)."
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Test 3: Remote command executed!"
  FAIL=$((FAIL + 1))
fi

# Test 4: Reverse Remote Forwarding Blocked
/c/Users/a/AppData/Local/Temp/openssh_portable/OpenSSH-Win64/sshd.exe \
  -d \
  -f C:/Users/a/AppData/Local/Temp/test_sshd/sshd_config \
  -p 2222 > /c/Users/a/AppData/Local/Temp/test_sshd/sshd4.log 2>&1 &
SSHD_PID=$!
sleep 1

set +e
timeout 2 ssh -p 2222 -i /c/Users/a/AppData/Local/Temp/test_sshd/client_key \
  -o StrictHostKeyChecking=no -o ConnectTimeout=2 -o ExitOnForwardFailure=yes \
  -N -R 28320:127.0.0.1:8320 a@127.0.0.1 >/dev/null 2>&1
RF_RC=$?
set -e
wait $SSHD_PID 2>/dev/null || kill $SSHD_PID 2>/dev/null || true

if [[ "$RF_RC" -ne 0 ]]; then
  echo "  [PASS] Test 4: Reverse remote forwarding rejected (exit code $RF_RC)."
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Test 4: Reverse forwarding was allowed!"
  FAIL=$((FAIL + 1))
fi

echo "Results: $PASS / $((PASS + FAIL)) passed."
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
