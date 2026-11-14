# SSH TUNNEL SECURITY & END-TO-END VERIFICATION REPORT
> **Historical document (2026-11-11, v1.0.0 era).** Kept for audit trail. The fix described here was the first v1.0.0 patch attempt. **v1.0.1 supersedes its remote-forwarding conclusion:** `permitlisten="127.0.0.1:1"` is defence in depth only, not a complete `-R` prohibition. The authoritative control is now a per-user `sshd` `Match` block with `PermitListen none`. Current evidence is in [PUBLIC-RELEASE-READINESS.md](PUBLIC-RELEASE-READINESS.md).

**Target Component:** SSH Tunnel & Key Restriction Architecture  
**Test Environment:** Isolated OpenSSH Daemon (OpenSSH_for_Windows 10.4p1 / OpenSSH 10.5p1 Client)  
**Date:** 2026-11-11  

---

## 1. Executive Summary & Critical Finding (DEFECT CONFIRMED)

### P0 Defect: v1.0.0 `authorized_keys` Completely Breaks SSH Forwarding
In `v1.0.0`, `generate_restricted_authorized_key_entry` produced:
```text
command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320" <PUBKEY>
```
**Empirical Evidence:**
When tested against an active OpenSSH daemon with local port forwarding (`ssh -N -L 18320:127.0.0.1:8320`):
- **Result:** FAILED (`CURL_FAILED`).
- **sshd Log:**
  `user: refused local port forward: originator 127.0.0.1 port 56213, target 127.0.0.1 port 8320`
  `debug1: server_input_channel_open: failure direct-tcpip`
- **Root Cause:** According to the OpenSSH `sshd(8)` specification, `no-port-forwarding` unconditionally disables all TCP forwarding channels. When `no-port-forwarding` is specified, `permitopen` is completely ignored and all port forwarding fails.

---

## 2. Tested Mitigation & Security Invariants

We independently tested the exact reference restrictions from the user specification:
```text
command="/bin/false",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320",permitlisten="127.0.0.1:1" <PUBKEY>
```

### Security Matrix & Live Test Results:

| Security Vector | Expected Behavior | Actual Empirical Result | Exit Code / Evidence | Status |
|---|---|---|---|---|
| **Local Forwarding to 127.0.0.1:8320** | Connected to Mock Backend | `HTTP 200 OK` ("MOCK_ACCOUNT_MANAGER_8320") | RC=0 | **PASS** |
| **Local Forwarding to Forbidden Port 8321** | Blocked | `CURL_FAILED` | sshd log: *Received request ... to connect to host 127.0.0.1 port 8321, but the request was denied.* | **PASS** |
| **Interactive Shell Execution** | Denied | Refused (`/bin/false` executed) | RC=1, no shell spawned | **PASS** |
| **Remote Command Execution (`whoami`)** | Denied | Forced-command `/bin/false` executed, user command ignored | RC=1 | **PASS** |
| **PTY Allocation** | Denied | `no-pty` enforced | TTY allocation refused | **PASS** |
| **Agent & X11 Forwarding** | Denied | `no-agent-forwarding`, `no-X11-forwarding` | Channel requests refused | **PASS** |
| **Reverse Remote Forwarding (`-R`)** | Denied | Key option `permitlisten="127.0.0.1:1"` rejects other ports; v1.0.1 adds `PermitListen none` in a `Match` block | RC=255: *Error: remote port forwarding failed for listen port 28320* | **PASS (v1.0.1 hardening)** |

---

## 3. Recommended Fix for Branch `fix/post-release-verification-v1.0.0`
Update `server-installer/lib/installer_core.sh`:
```bash
generate_restricted_authorized_key_entry() {
  local pubkey="$1"
  local target_host="${2:-127.0.0.1}"
  local target_port="${3:-8320}"
  local clean_key
  clean_key=$(echo "$pubkey" | tr -d '\r\n')
  
  if [[ -z "$clean_key" ]]; then
    echo "[ERROR] Public key cannot be empty" >&2
    return 1
  fi

  echo "command=\"/bin/false\",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen=\"${target_host}:${target_port}\",permitlisten=\"127.0.0.1:1\" ${clean_key}"
}
```
This guarantees that local forwarding to Account Manager succeeds, while shell, commands, PTY, agent, X11, reverse forwarding, and unauthorized ports are strictly blocked.
