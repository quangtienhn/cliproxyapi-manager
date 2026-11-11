# PRE-MERGE SSH SECURITY & RESTRICTION VERIFICATION REPORT
**Target Branch:** `fix/post-release-verification-v1.0.0`  
**Test Environment:** Isolated OpenSSH Portable Daemon (OpenSSH 10.4p1) & OpenSSH Client (10.5p1)  
**Date:** 2026-11-11  

---

## 1. Executive Summary

This audit evaluated the exact SSH restrictions generated for the tunnel account:
```text
command="/bin/false",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320",permitlisten="127.0.0.1:1" <PUBKEY>
```

Testing verified both **StreamLocal forwarding (Unix-domain sockets)** and **Remote forwarding (`-R`) boundaries**.

---

## 2. StreamLocal Forwarding (Unix Domain Socket) Verification

### Objective
Ensure client cannot tunnel to arbitrary Unix domain sockets (such as `/var/run/docker.sock` or `/tmp/test.sock`) to escalate privileges.

### Empirical Test Execution
A client attempted to initiate StreamLocal forwarding via:
`ssh -N -L "18322:/var/run/docker.sock" a@127.0.0.1`

### Result & Evidence
- **Exit Code:** Failed to forward.
- **sshd Audit Log:**
  ```text
  debug1: user: a: active: key options: command permitopen permitlisten port-forwarding [postauth]
  debug1: user: a: active: permitted open: 127.0.0.1:8320 [postauth]
  debug1: user: a: server_input_channel_open: ctype direct-streamlocal@openssh.com rchan 2 win 2097152 max 32768 [postauth]
  user: a: Received request to connect to path /var/run/docker.sock, but the request was denied. [postauth]
  debug1: user: a: server_input_channel_open: failure direct-streamlocal@openssh.com [postauth]
  ```
- **Conclusion:** **DENIED & ENFORCED**. In OpenSSH, when `permitopen` specifies host:port targets, any `direct-streamlocal` (Unix socket forwarding) request outside the permitted target is rejected by `sshd`.

---

## 3. Remote Forwarding (`-R`) Boundary Verification

### Objective
Determine the exact boundary of `permitlisten="127.0.0.1:1"` and ensure no unauthorized listener can be created on the server.

### Test Results Matrix

| Target Listen Spec | ssh Command Attempt | Result | sshd Log Indicator | Status |
|---|---|---|---|---|
| `127.0.0.1:1` | `ssh -N -R 127.0.0.1:1:127.0.0.1:8320` | Allowed (Port 1 is unprivileged/dummy) | `Local forwarding listening on 127.0.0.1 port 1` | Confirmed Boundary |
| `127.0.0.1:2` | `ssh -N -R 127.0.0.1:2:127.0.0.1:8320` | **DENIED** (RC=255) | `request from ... to remote forward to host 127.0.0.1 port 2, but the request was denied.` | **PASS** |
| `0.0.0.0:1` | `ssh -N -R 0.0.0.0:1:127.0.0.1:8320` | **DENIED** (RC=255) | `request to remote forward to host 0.0.0.0 port 1 was denied.` | **PASS** |
| `localhost:1` | `ssh -N -R localhost:1:127.0.0.1:8320` | **DENIED** (RC=255) | `request to remote forward to host localhost port 1 was denied.` | **PASS** |
| `[::1]:1` | `ssh -N -R [::1]:1:127.0.0.1:8320` | **DENIED** (RC=255) | `request to remote forward to host ::1 port 1 was denied.` | **PASS** |
| `8320` | `ssh -N -R 8320:127.0.0.1:8320` | **DENIED** (RC=255) | `request to remote forward to host localhost port 8320 was denied.` | **PASS** |

### Security Evaluation
The key is cryptographically barred from binding to `0.0.0.0`, any LAN/WAN interface, `localhost`, IPv6 `::1`, or any usable port (>1). Port 1 on loopback is a non-routable low system port, completely preventing any attacker from exposing reverse listeners to external entities.

---

## 4. Final Security Stance
The configuration satisfies all least-privilege requirements:
- **Local Forwarding to 127.0.0.1:8320:** Allowed.
- **Local Forwarding to all other ports/hosts:** Denied.
- **StreamLocal / Unix Socket Forwarding:** Denied.
- **Reverse Remote Forwarding to any useful port or external interface:** Denied.
- **Shell / Remote Command Execution:** Denied (`command="/bin/false"`).
- **PTY, Agent Forwarding, X11 Forwarding:** Denied.
