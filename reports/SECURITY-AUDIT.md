# SECURITY AUDIT & THREAT MODEL REPORT
**Date:** 2026-11-11  
**Project:** CLIProxyAPI Account Manager Easy Installer v1.0.0  
**Scanner Utilized:** Gitleaks v8.x, Static Source Analysis, OpenSSH Runtime Verification  

---

## 1. Automated Secret Scanning
- **Tool:** Gitleaks
- **Scope:** Complete project directory `D:\Workspace\CLI2API-Easy-Installer` (All scripts, templates, config, tests, reports).
- **Result:** `no leaks found`. Zero private keys, passwords, API tokens, or management secrets in source or history.

---

## 2. Vulnerability & Findings Matrix

| Finding ID | Severity | Category | Description | Status | Evidence & Resolution |
|---|---|---|---|---|---|
| **SEC-01** | **CRITICAL (P0)** | Access Control / Broken Forwarding | `no-port-forwarding` in `authorized_keys` prevents legitimate tunnel traffic | **CONFIRMED** | Proven in OpenSSH test bed. Resolved by removing `no-port-forwarding` and strictly applying `permitopen="127.0.0.1:8320",permitlisten="127.0.0.1:1"`. |
| **SEC-02** | Low | Information Disclosure | Diagnostics logging sensitive values | **MITIGATED** | `redact_sensitive` strips tokens, keys, passwords before stdout. |
| **SEC-03** | Medium | Integrity | Backup tampering / malicious archive | **MITIGATED** | `restore.sh` enforces strict `sha256sum -c SHA256SUMS.txt` before touching live state. |
| **SEC-04** | High | Network Exposure | Management API WAN/LAN exposure | **MITIGATED** | Kept strictly on `127.0.0.1:8317` with `allow-remote: false`. |
| **SEC-05** | High | Remote Code Execution | SSH shell on tunnel account | **MITIGATED** | Forced command `/bin/false` and user shell set to `/bin/false` prevents command execution. |

---

## 3. Threat Model Verification
1. **Compromised Ingress Tunnel Key:** If the client key from HAOS is stolen, the attacker can **only** forward TCP traffic to `127.0.0.1:8320`. They cannot get a shell, run commands, allocate a PTY, or forward traffic to other ports/networks.
2. **Untrusted Host Key Attack:** The HAOS add-on enforces `StrictHostKeyChecking=yes` and validates pinned host keys from `known_hosts`, mitigating man-in-the-middle attacks.
