# POST-RELEASE BASELINE & INITIAL DISCOVERY REPORT
**Release Tag:** `v1.0.0`  
> **Historical document (2026-11-11, v1.0.0 era).** Kept for audit trail. It describes the state *before* the v1.0.1 fixes. For current status and evidence, see [PUBLIC-RELEASE-READINESS.md](PUBLIC-RELEASE-READINESS.md). References to specific private hostnames or addresses have been removed; production systems were never accessed or modified.
**Target Repository:** `quangtienhn/cliproxyapi-account-manager-easy-installer`  
**Release Checksum:** `3e1d5fe93a86ceb6b6e8982d816e8ec1bdf9a053b127c01fbef458e113f878b6`  
**Baseline Date:** 2026-11-11  

---

## 1. Repository & Git Status
- **Current Branch:** `main` (commit `6706176` tracking `origin/main`).
- **Release Status:** Published GitHub Release `v1.0.0` with assets:
  - `cliproxyapi-account-manager-easy-installer-v1.0.0.tar.gz`
  - `cliproxyapi-account-manager-easy-installer-v1.0.0.tar.gz.sha256`
- **Asset Integrity:** SHA256 matches exact byte hash: `3e1d5fe93a86ceb6b6e8982d816e8ec1bdf9a053b127c01fbef458e113f878b6`.
- **Repository Integrity:** All 32 tracked files in `SHA256SUMS.txt` verified OK via `sha256sum -c SHA256SUMS.txt`.

---

## 2. Inventory of Packaged Artifacts
1. **Embedded Application Bundles (`server-installer/embedded/`):**
   - `cliproxyapi-account-manager-v1.0.1.tar.gz` (Checked against `SHA256SUMS-v1.0.1.txt` -> MATCH).
   - `yaml-dependency.tar.gz` (Pre-packaged pure-JS dependency for node ESM secret synchronizer).
2. **Server Installer Components (`server-installer/`):**
   - `install.sh`, `update.sh`, `backup.sh`, `restore.sh`, `diagnostics.sh`, `uninstall.sh`.
   - `bin/cliproxy-manager` (Unified management CLI).
   - `lib/installer_core.sh` (Core helper library).
   - `templates/` (`manager.env.template`, `cliproxyapi-account-manager.service`).
3. **HAOS Add-on Components (`haos-addon/`):**
   - `config.yaml`, `Dockerfile`, `build.yaml`.
   - `rootfs/run.sh`, `rootfs/proxy.mjs`.

---

## 3. Baseline Audit of Prior Verification Claims
The initial release marked several capabilities as "VERIFIED" which, upon strict technical audit, were verified only via unit test or synthetic mocks.

| Capability | Initial Status | Technical Reality & Baseline Deficiencies |
|---|---|---|
| SSH Key Restrictions (`authorized_keys`) | VERIFIED | **Unit tested string pattern only.** OpenSSH man pages explicitly state: `no-port-forwarding` unconditionally forbids TCP forwarding. Placing `no-port-forwarding` alongside `permitopen` completely disables `ssh -L` forwarding in OpenSSH! |
| Cross-Platform Debian / Ubuntu | VERIFIED | **Unit / bash syntax check only.** Not tested against actual package managers (`apt`), real `systemd` service lifecycle, or varying OS distributions. |
| HAOS Ingress Reverse Proxy | VERIFIED | **Regex & mock HTTP server test only.** Not tested with concurrent streams, upstream error handling under live load, or end-to-end SSH tunnel. |
| Docker Multi-Arch Build | NOT VERIFIED | Needs build & runtime verification on isolated containers. |
| Production Systems Safety | VERIFIED | Guaranteed untouched. Reference production hardware and the Home Assistant OS instance remained completely isolated and were not modified. |

---

## 4. Immediate High-Priority Finding (P0 Defect Identified)
In `server-installer/lib/installer_core.sh` line 54:
```bash
echo "command=\"/bin/false\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen=\"${target_host}:${target_port}\" ${clean_key}"
```
**OpenSSH Specification Contradiction:**
According to `sshd(8)`:
- `no-port-forwarding`: "Forbids TCP forwarding when this key is used for authentication. Any port forward requests by the client will return an error."
- `permitopen="host:port"`: Limits local port forwarding (`-L`), but **only if port forwarding is enabled**.
- If `no-port-forwarding` (or `restrict` without `port-forwarding`) is specified, SSH connections requesting `-L 127.0.0.1:UPSTREAM:127.0.0.1:8320` will be rejected by `sshd` with `channel 1: open failed: administratively prohibited`!
- The correct OpenSSH secure restriction syntax is:
  `restrict,port-forwarding,permitopen="127.0.0.1:8320"` or `command="/bin/false",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320"`.

This will be thoroughly tested in Phase B under an isolated OpenSSH daemon.
