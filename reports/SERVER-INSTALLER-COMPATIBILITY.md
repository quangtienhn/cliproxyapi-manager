# SERVER INSTALLER CROSS-PLATFORM COMPATIBILITY REPORT
> **Historical document (2026-11-11, v1.0.0 era).** Kept for audit trail. All results below are **simulations** on a Windows/Git Bash runtime, not native Linux. v1.0.1 re-ran the same matrix. Native Debian/Ubuntu installs remain **not verified**; see [PUBLIC-RELEASE-READINESS.md](PUBLIC-RELEASE-READINESS.md).

**Target OS Scope:** Debian 12 (Bookworm), Debian 13 (Trixie), Ubuntu 22.04 LTS (Jammy), Ubuntu 24.04 LTS (Noble)  
**Target Architectures:** AMD64 (x86_64) & ARM64 (aarch64)  
**Verification Method:** Isolated Cross-Platform Simulation Matrix & Filesystem Mock  
**Date:** 2026-11-11  

---

## 1. Platform Matrix Results

| Target OS | Architecture | Environment | Fresh Install | Idempotent Re-run | Diagnostics | Status |
|---|---|---|---|---|---|---|
| Debian 12 | AMD64 | Simulated Debian 12 FS | PASS | PASS | PASS | **VERIFIED (Simulation)** |
| Debian 12 | ARM64 | Simulated Debian 12 ARM64 FS | PASS | PASS | PASS | **VERIFIED (Simulation)** |
| Debian 13 | AMD64 | Simulated Debian 13 FS | PASS | PASS | PASS | **VERIFIED (Simulation)** |
| Debian 13 | ARM64 | Simulated Debian 13 ARM64 FS | PASS | PASS | PASS | **VERIFIED (Simulation)** |
| Ubuntu 22.04 LTS | AMD64 | Simulated Ubuntu 22.04 FS | PASS | PASS | PASS | **VERIFIED (Simulation)** |
| Ubuntu 24.04 LTS | AMD64 | Simulated Ubuntu 24.04 FS | PASS | PASS | PASS | **VERIFIED (Simulation)** |
| Ubuntu 24.04 LTS | ARM64 | Simulated Ubuntu 24.04 ARM64 FS | PASS | PASS | PASS | **VERIFIED (Simulation)** |

---

## 2. Invariants & Lifecycle Checks
- **Prerequisite Enforcement:** Validates CPU architecture (`amd64` / `arm64`) and Node.js version (>= 18 required).
- **Existing Deployment Discovery:** Detects existing installation gracefully, preserves existing `manager.env` without overwriting custom ports or secrets, and creates an automatic timestamped snapshot.
- **Atomic Application Extraction:** Staged extracted directory is validated before being swapped in place.
- **CLI Symlink Registration:** Creates `/usr/local/bin/cliproxy-manager` to ensure smooth operator workflows.
