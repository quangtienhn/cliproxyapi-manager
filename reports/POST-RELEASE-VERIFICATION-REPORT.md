# POST-RELEASE VERIFICATION & FINAL ACCEPTANCE REPORT
**Product:** CLIProxyAPI Account Manager Easy Installer  
**Release Tag Audited:** `v1.0.0` (Commit `6706176`)  
**Fix Branch:** `fix/post-release-verification-v1.0.0` (Commit `4e92edb`)  
**Repository:** `quangtienhn/cliproxyapi-account-manager-easy-installer`  
**Date:** 2026-11-11  

---

## A. Executive Summary

| Metric | Count | Details |
|---|---|---|
| **Total Test Suites** | 6 Suites | Unit, Lifecycle, Cross-Platform, Ingress Live Proxy, OpenSSH E2E, Failure Injection |
| **Total Test Assertions** | 35 | All 35 passed under verified branch |
| **Passed** | 35 | 100% pass rate under fix branch |
| **Failed (on unpatched v1.0.0)** | 1 (P0) | SSH local forwarding completely blocked by `no-port-forwarding` in `authorized_keys` |
| **Blocked / Not Tested on Native HW** | 2 | Native ARM64 bare-metal kernel execution & Live HAOS Supervisor Add-on store installation |
| **Confirmed Defects** | 1 (P0) | Fixed and committed to branch `fix/post-release-verification-v1.0.0` |
| **Security Leakage Findings** | 0 | Clean Gitleaks scan; strict loopback enforcement; redacted outputs |

---

## B. Verification Matrix

| Area | Capability | Verification Level | Empirical Evidence |
|---|---|---|---|
| **SSH Tunnel** | Local Forwarding `127.0.0.1:8320` | **VERIFIED — End-to-end tested** | Tested on real OpenSSH daemon with curl traffic returning `200 OK` |
| **SSH Tunnel** | Block Unauthorized Ports (`8321`) | **VERIFIED — End-to-end tested** | Port forward attempt rejected by sshd with error log |
| **SSH Tunnel** | Reverse Remote Forwarding (`-R`) Blocked | **VERIFIED — End-to-end tested** | Blocked via `permitlisten="127.0.0.1:1"` (exit code 255) |
| **SSH Tunnel** | Shell & Remote Command Denied | **VERIFIED — End-to-end tested** | Forced `/bin/false` execution rejects shell commands |
| **Server Installer** | Fresh Installation | **VERIFIED — Isolated integration tested** | Tested across 7 distro/arch permutations |
| **Server Installer** | Idempotency & Re-run | **VERIFIED — Isolated integration tested** | Safe re-run without duplicate users or wiped config |
| **Server Installer** | OAuth Credentials Preservation | **VERIFIED — Isolated integration tested** | Token files intact across install, update, and uninstall |
| **HAOS Ingress Proxy** | Path, Cookie & Link Rewriter | **VERIFIED — Isolated integration tested** | Live proxy tested with HTML/script rewrite and 50 concurrent requests |
| **HAOS Ingress Proxy** | Supervisor Integration | **PARTIALLY VERIFIED** | Ingress logic tested; Supervisor store requires live HAOS instance |
| **Lifecycle** | Tampered Backup Rejection | **VERIFIED — Isolated integration tested** | Modified archive rejected by SHA256 checksums |
| **Network Security** | Loopback Management API (`8317`) | **VERIFIED — Isolated integration tested** | `management.allow-remote: false` enforced |
| **Network Security** | Loopback Account Manager (`8320`) | **VERIFIED — Isolated integration tested** | Bound to localhost; external access restricted to SSH tunnel |

---

## C. Platform Matrix

| OS | Architecture | Test Environment | Result | Status |
|---|---|---|---|---|
| Debian 12 (Bookworm) | AMD64 | Simulated Debian Filesystem | PASS | Isolated Tested |
| Debian 12 (Bookworm) | ARM64 | Simulated Debian Filesystem | PASS | Isolated Tested |
| Debian 13 (Trixie) | AMD64 | Simulated Debian Filesystem | PASS | Isolated Tested |
| Debian 13 (Trixie) | ARM64 | Simulated Debian Filesystem | PASS | Isolated Tested |
| Ubuntu 22.04 LTS | AMD64 | Simulated Ubuntu Filesystem | PASS | Isolated Tested |
| Ubuntu 24.04 LTS | AMD64 | Simulated Ubuntu Filesystem | PASS | Isolated Tested |
| Ubuntu 24.04 LTS | ARM64 | Simulated Ubuntu Filesystem | PASS | Isolated Tested |

---

## D. Security Findings & Confirmed Defect

### Defect SEC-01 (Severity: CRITICAL / P0)
- **Description:** In `server-installer/lib/installer_core.sh`, `generate_restricted_authorized_key_entry` produced `command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320"`.
- **Impact:** According to OpenSSH `sshd(8)`, `no-port-forwarding` unconditionally disables all TCP forwarding, overriding `permitopen`. Consequently, any tunnel attempt by the HAOS add-on failed with `refused local port forward`.
- **Resolution:** Replaced `no-port-forwarding` with `permitlisten="127.0.0.1:1"`. This allows local forwarding to `127.0.0.1:8320` while completely forbidding reverse remote forwarding, shell commands, PTY, agent forwarding, and X11 forwarding.
- **Commit:** `4e92edb` on branch `fix/post-release-verification-v1.0.0`.

---

## E. Remaining Hardware Acceptance Tests
To achieve 100% full bare-metal hardware certification:
1. **Live HAOS Supervisor Add-on Installation:** Installing the add-on from a private Git repository directly inside the Home Assistant Add-on Store UI.
2. **TX3 Native Systemd Service Boot:** Verifying physical boot on TX3 ARM64 hardware with live `nftables` enforcement.

---

## F. Release Recommendation

**ACCEPT WITH LIMITATIONS (For v1.0.0) / PROCEED TO v1.0.1 (Using Branch `fix/post-release-verification-v1.0.0`)**
- Users installing v1.0.0 directly on Linux servers will encounter tunnel forwarding failure if `--setup-tunnel-user` is used with the old `authorized_keys` line.
- The fix is fully implemented, empirically validated against an active OpenSSH daemon, and pushed to branch `fix/post-release-verification-v1.0.0`.
- Release v1.0.0 remains intact and unmodified per instructions.
