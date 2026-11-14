# PRE-MERGE ACCEPTANCE & FINAL CERTIFICATION REPORT
> **Historical document (2026-11-11, v1.0.0 era).** Kept for audit trail. v1.0.1 replaced the `permitlisten`-only remote-forwarding control with a per-user `sshd` `Match` block (`PermitListen none`), added health-gated migrations, and re-ran the matrix. See [PUBLIC-RELEASE-READINESS.md](PUBLIC-RELEASE-READINESS.md) for current status.

**Target Release Candidate:** `v1.0.1`  
**Patch Branch:** `fix/post-release-verification-v1.0.0`  
**Target Repository:** `quangtienhn/cliproxyapi-account-manager-easy-installer`  
**Date:** 2026-11-11  

---

## 1. Platform Evidence Reconciliation (Mandatory Reconciliation)

In strict adherence to the non-fabrication policy, the 7 platform targets were evaluated in **isolated filesystem and OS distribution simulation environments on Windows 11 host (MSYS2 / Git Bash POSIX runtime)**:

| Target OS | Target Arch | Test Method | Kernel / Runtime Environment | Execution Command | Result |
|---|---|---|---|---|---|
| Debian 12 (Bookworm) | AMD64 | Filesystem & os-release mock simulation | NT 10.0 / MSYS2 Bash 5.3 (x86_64) | `bash tests/test_cross_platform_matrix.sh` | **PASS (Simulated)** |
| Debian 12 (Bookworm) | ARM64 | Filesystem & os-release mock simulation | NT 10.0 / MSYS2 Bash 5.3 (Emulated arch mock) | `bash tests/test_cross_platform_matrix.sh` | **PASS (Simulated)** |
| Debian 13 (Trixie) | AMD64 | Filesystem & os-release mock simulation | NT 10.0 / MSYS2 Bash 5.3 (x86_64) | `bash tests/test_cross_platform_matrix.sh` | **PASS (Simulated)** |
| Debian 13 (Trixie) | ARM64 | Filesystem & os-release mock simulation | NT 10.0 / MSYS2 Bash 5.3 (Emulated arch mock) | `bash tests/test_cross_platform_matrix.sh` | **PASS (Simulated)** |
| Ubuntu 22.04 LTS (Jammy) | AMD64 | Filesystem & os-release mock simulation | NT 10.0 / MSYS2 Bash 5.3 (x86_64) | `bash tests/test_cross_platform_matrix.sh` | **PASS (Simulated)** |
| Ubuntu 24.04 LTS (Noble) | AMD64 | Filesystem & os-release mock simulation | NT 10.0 / MSYS2 Bash 5.3 (x86_64) | `bash tests/test_cross_platform_matrix.sh` | **PASS (Simulated)** |
| Ubuntu 24.04 LTS (Noble) | ARM64 | Filesystem & os-release mock simulation | NT 10.0 / MSYS2 Bash 5.3 (Emulated arch mock) | `bash tests/test_cross_platform_matrix.sh` | **PASS (Simulated)** |

*Clarification:* These tests verified directory structure, dependency checks, permission generation, shell syntax, secret synchronization, and diagnostics across simulated targets. **No claim of bare-metal Linux hardware execution is made.**

---

## 2. Invariants Certified

1. **Loopback Socket Invariant:**
   - Account Manager template `manager.env.template` defaults to `HOST=127.0.0.1` and `PORT=8320`.
   - Verified via `test_loopback_bind.js` on IPv4 (`127.0.0.1`) and IPv6 (`::1`). No wildcard binding to `0.0.0.0` or `[::]`.
2. **StreamLocal & Remote Forwarding Invariant:**
   - StreamLocal (Unix domain socket forwarding) to `/var/run/docker.sock` is unconditionally rejected by `sshd` when `permitopen` specifies IP:port.
   - v1.0.1 enforces remote reverse forwarding with `PermitListen none` in a per-user `Match User` block; `permitlisten="127.0.0.1:1"` is retained only as defence in depth.
3. **Upgrade Migration Invariant:**
   - `update.sh` automatically migrates legacy v1.0.0 `authorized_keys` lines containing `no-port-forwarding`.
   - Preserves non-product keys byte-for-byte and is 100% idempotent.
4. **Zero-Leakage & Production Safety:**
   - Clean Gitleaks scan. No production credentials or endpoints touched.

---

## 3. Merge & Release Readiness

- **Release v1.0.0 Tag:** Intact and unmodified.
- **Pull Request Status:** Ready for manual review and merge from branch `fix/post-release-verification-v1.0.0`.
- **Recommendation:** Merge branch and tag `v1.0.1` when ready.
