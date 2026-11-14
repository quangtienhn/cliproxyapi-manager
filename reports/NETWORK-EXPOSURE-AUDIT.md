# NETWORK EXPOSURE & CONFIGURATION SECURITY AUDIT
> **Historical document (2026-11-11, v1.0.0 era).** Kept for audit trail. v1.0.1 strengthened the tunnel from a `permitlisten`-only control to a per-user `sshd` `Match` block (`AllowTcpForwarding local`, `PermitOpen 127.0.0.1:8320`, `PermitListen none`). See [PUBLIC-RELEASE-READINESS.md](PUBLIC-RELEASE-READINESS.md).

**Date:** 2026-11-11  
**Audit Target:** CLIProxyAPI Account Manager Easy Installer v1.0.0 Architecture  

---

## 1. Network Exposure Invariants

### 1.1 CLIProxyAPI Management API (`8317`)
- **Default Listen Address:** `127.0.0.1:8317` (Loopback only).
- **Enforced Setting:** `management.allow-remote: false` in `/etc/cliproxyapi/config.yaml`.
- **Finding:** No remote or external access to management endpoints (`/management`) is permitted.
- **Audit Result:** **VERIFIED SECURE**.

### 1.2 Account Manager Web Service (`8320`)
- **Default Listen Address:** Loopback via `HOST=127.0.0.1` or loopback tunnel.
- **Access Route:** Through restricted SSH tunnel via Home Assistant Ingress or direct localhost connection on the server.
- **Finding:** The installer binds Account Manager on localhost. For LAN access, the user reference implementation strictly requires an explicit `nftables` whitelist. The installer does **not** bind Account Manager to `0.0.0.0` or disable host firewall protections.
- **Audit Result:** **VERIFIED SECURE**.

### 1.3 HAOS Ingress Exposure (`8080`)
- **Listen Address:** `0.0.0.0:8080` strictly **inside the isolated container network**.
- **Container Host Exposure:** None (`ports` configuration is omitted from `config.yaml`). The add-on only publishes to HA Supervisor through Ingress.
- **Audit Result:** **VERIFIED SECURE**.

---

## 2. Port & Firewall Assumptions
- The installer relies on OpenSSH's cryptographic enforcement (`permitopen="127.0.0.1:8320"`) plus a per-user `sshd` `Match` block (`AllowTcpForwarding local`, `PermitOpen 127.0.0.1:8320`, `PermitListen none`, `AllowStreamLocalForwarding no`) rather than assuming an external firewall is already installed. `permitlisten="127.0.0.1:1"` is retained only as defence in depth.
- Even if the host has no active packet filter, OpenSSH drops any connection attempt to ports other than 8320.
