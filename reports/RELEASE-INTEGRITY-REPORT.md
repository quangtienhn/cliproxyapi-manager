# RELEASE ARTIFACT & INTEGRITY VERIFICATION REPORT
**Target Release:** `v1.0.0`  
**GitHub Repository:** `quangtienhn/cliproxyapi-account-manager-easy-installer`  
**Date:** 2026-11-11  

---

## 1. Asset Cryptographic Verification

| Asset File | Published SHA256 Checksum | Verified Byte Hash | Status |
|---|---|---|---|
| `cliproxyapi-account-manager-easy-installer-v1.0.0.tar.gz` | `3e1d5fe93a86ceb6b6e8982d816e8ec1bdf9a053b127c01fbef458e113f878b6` | `3e1d5fe93a86ceb6b6e8982d816e8ec1bdf9a053b127c01fbef458e113f878b6` | **MATCH** |
| `cliproxyapi-account-manager-easy-installer-v1.0.0.tar.gz.sha256` | Formatted checksum record | Exact match with archive | **MATCH** |

---

## 2. Archive File Structure & Permissions
All 32 files in the release archive match repository manifests:
- Embedded Account Manager package: `server-installer/embedded/cliproxyapi-account-manager-v1.0.1.tar.gz` (Checked against upstream SHA256 -> MATCH).
- Shell scripts retain executable flags (`0755` permissions).
- Templates and configurations have least-privilege mode specifications.

---

## 3. Git Release & Tag Immutability
- Release Tag `v1.0.0` points to commit `6706176`.
- In strict adherence to Section 2.2, release `v1.0.0` assets and Git history remain **immutable**.
- Identified fixes and verified improvements are committed to a dedicated fix branch (`fix/post-release-verification-v1.0.0`).
