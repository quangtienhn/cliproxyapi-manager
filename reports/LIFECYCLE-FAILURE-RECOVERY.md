# LIFECYCLE & FAILURE RECOVERY VERIFICATION REPORT
> **Historical document (2026-11-11, v1.0.0 era).** Kept for audit trail. In v1.0.1, failed updates roll back and leave SSH access untouched, and `uninstall --purge-data` additionally removes the managed tunnel key and sshd policy. See `tests/test_update_rollback.sh` and [PUBLIC-RELEASE-READINESS.md](PUBLIC-RELEASE-READINESS.md).

**Target Workflows:** Backup, Restore, Update, Rollback, Uninstall  
**Test Suite:** `tests/test_failure_recovery.sh` & `tests/integration/test_lifecycle.sh`  
**Date:** 2026-11-11  

---

## 1. Scenario Results

| Lifecycle Stage | Scenario Tested | Observation & Result | Status |
|---|---|---|---|
| **Backup Integrity** | Generate full snapshot with metadata & SHA256 | Verified `SHA256SUMS.txt`, metadata.env, config, auths | **PASS** |
| **Restore Verification** | Corrupted backup file (modified `manager.env`) | Checksum validation aborted restore before live mutation | **PASS** |
| **Pre-Restore Snapshot** | Automatic rollback point creation | Safety snapshot saved under `pre_restore_safety_*` | **PASS** |
| **Update Rollback** | Failed health check simulation | Previous application directory and services preserved | **PASS** |
| **Uninstall Safety** | Standard uninstallation (`cliproxy-manager uninstall`) | Application removed; OAuth data and configs preserved | **PASS** |
| **Uninstall Purge** | Explicit `--purge-data` invocation | Data directories deleted only with explicit confirmation | **PASS** |

---

## 2. Invariants Guaranteed
- **Pre-execution Snapshot:** Any destructive or upgrading action takes a snapshot first.
- **Fail-Safe Integrity:** Any archive tampering or byte corruption is caught by cryptographic checksum validation before applying changes.
- **Zero-Loss Deletion:** Uninstaller strictly preserves `/var/lib/cliproxyapi/auths` and `/var/backups` by default.
