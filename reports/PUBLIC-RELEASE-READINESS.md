# Public Release Readiness — v1.0.1 Release Candidate

**Status:** Release candidate on branch `release/public-readiness-v1.0.1`.  
**Not released:** no `v1.0.1` tag, GitHub release, package, or Docker image exists.  
**Repository visibility:** still private. Changing visibility is an owner action, described at the end of this document.  
**Audit date:** 2026-11-12.

This document is the current evidence index. Older reports in `reports/` that were written during the v1.0.0 audit are retained for history and carry a banner noting that v1.0.1 supersedes their remote-forwarding conclusions.

---

## 1. Scope

The product is two cooperating pieces:

1. **Server installer and lifecycle CLI** for the CLIProxyAPI Account Manager on Debian 12/13 and Ubuntu LTS, AMD64 and ARM64.
2. **Home Assistant OS add-on** that exposes the Account Manager through Ingress over a restricted SSH tunnel.

CLIProxyAPI itself is an external project and is **not** installed, configured, or verified by this repository.

---

## 2. What changed since v1.0.0

| Area | v1.0.0 | v1.0.1 candidate |
| --- | --- | --- |
| Tunnel key | `no-port-forwarding` present, so `permitopen` never worked | Option removed; `permitopen="127.0.0.1:8320"` works |
| Remote forwarding | Only `permitlisten="127.0.0.1:1"` | Per-user `sshd` `Match` block with `AllowTcpForwarding local`, `AllowStreamLocalForwarding no`, `PermitOpen 127.0.0.1:8320`, `PermitListen none` |
| `authorized_keys` writes | Overwrote the file | Appends and de-duplicates; unrelated keys preserved byte-for-byte |
| Existing v1.0.0 installs | Never migrated | Idempotent migration with timestamped backup |
| Bind address | Template used `0.0.0.0` | `HOST=127.0.0.1`, enforced on install, update, and restore |
| Failed update | Warned and exited 0 | Restores previous tree, restarts, re-checks, exits non-zero |
| SSH migrations on update | Before health check | Only after the new version is healthy |
| HAOS host key | Permissive inline parsing | Strict `hostkey.mjs`, fails closed; `UpdateHostKeys=no`, `VerifyHostKeyDNS=no` |
| HAOS private fallbacks | Present | Removed |
| Uninstall | Always preserved everything | Default preserves data and SSH; `--purge-data` removes managed key and sshd policy, keeps backups |

Full detail: [../CHANGELOG.md](../CHANGELOG.md) and [../docs/UPGRADING.md](../docs/UPGRADING.md).

---

## 3. Evidence categories

Every claim below uses one of these labels. They are not interchangeable.

| Label | Meaning |
| --- | --- |
| **Native** | Ran on the real target OS and architecture |
| **VM / container** | Ran in a real virtual machine or container |
| **Real process** | Ran the actual shipped application binary/script, but on the audit host |
| **Emulated / simulated** | Mocked OS metadata, filesystem, or architecture |
| **Unit** | Pure function or string-level assertions |

---

## 4. Validation matrix

| Area | Method | Label | Result |
| --- | --- | --- | --- |
| Installer core helpers | `bash tests/unit/test_installer_core.sh` | Unit | 9/9 pass |
| HAOS proxy logic | `node tests/unit/test_haos_proxy.js` | Unit | pass |
| Install → backup → restore → diagnostics → uninstall | `bash tests/integration/test_lifecycle.sh` | Simulated OS, real scripts | pass |
| 7 Debian/Ubuntu permutations | `bash tests/test_cross_platform_matrix.sh` | Emulated/simulated | 7/7 pass |
| Backup tamper, symlink injection, uninstall safety | `bash tests/test_failure_recovery.sh` | Simulated OS, real scripts | 4/4 pass |
| Loopback socket invariants | `node tests/test_loopback_bind.js` | Real process | 3/3 pass |
| Ingress path/cookie/redirect rewrite, 50 concurrent requests | `node tests/test_haos_proxy_live.js` | Real proxy process, mock upstream | pass |
| `authorized_keys` append and v1.0.0 migration | `bash tests/test_migration_logic.sh` | Unit + temp files | 18/18 pass |
| Per-user sshd policy install/remove/rollback | `bash tests/test_sshd_policy.sh` | Unit + temp files | 15/15 pass |
| Failed update rollback | `bash tests/test_update_rollback.sh` | Simulated OS, real scripts | 7/7 pass |
| v1.0.0 → v1.0.1 upgrade | `bash tests/test_upgrade_migration.sh` | Simulated OS, real scripts | 15/15 pass |
| HAOS host-key parser | `node tests/test_hostkey_parser.js` | Unit | 11/11 pass |
| Real Account Manager binding and restart | `node tests/test_real_service_loopback.js` | Real shipped app on audit host | 16/16 pass |
| Real OpenSSH forwarding restrictions | `bash tests/test_ssh_hardening.sh` | Real sshd, real ssh client | 20/20 pass |
| Repository hygiene and release invariants | `node tests/test_repo_hygiene.js` | Static | 65/65 pass |

`bash tests/run_all.sh` runs all suites and prints a pass/fail/skip summary. Final local run: **15 passed, 0 failed, 0 skipped**. A skipped SSH suite is counted as **skipped**, never as passed.

### What the SSH suite actually proved

Against a real OpenSSH daemon with the generated key and the generated per-user policy:

- local forward to `127.0.0.1:8320` works;
- local forwards to `127.0.0.1:8321`, `127.0.0.1:8317`, `/var/run/docker.sock`, and `/tmp/other.sock` are denied;
- remote forwards to `127.0.0.1:1`, `127.0.0.1:2`, `0.0.0.0:1`, `localhost:1`, `[::1]:1`, and `8320` are denied by the policy;
- shell, remote command, and PTY are denied;
- an empty, malformed, missing, or mismatched pinned host key is rejected, while the correct pin is accepted.

### What the real-service suite actually proved

The shipped Account Manager process (extracted from the embedded bundle) was started and its sockets inspected:

- it listens on `127.0.0.1` only;
- there is no `0.0.0.0` or `[::]` listener;
- every detected host LAN address fails to reach it;
- restarting the process reproduces the same invariants;
- when explicitly configured for IPv6 loopback it listens on `::1` and not on IPv4.

Host LAN addresses are discovered at runtime and are deliberately not recorded in this document.

---

## 5. Findings

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| SEC-01 | Critical | v1.0.0 `no-port-forwarding` broke every tunnel forward | Fixed; migration tested |
| SEC-02 | High | Remote forwarding was only weakly restricted | Fixed with per-user `PermitListen none`; E2E tested |
| SEC-03 | High | Failed update could report success and mutate SSH access | Fixed with health gate, rollback, and post-success migrations |
| SEC-04 | High | Installing a tunnel key overwrote unrelated administrator keys | Fixed; preserved byte-for-byte and tested |
| SEC-05 | Medium | Legacy `HOST=0.0.0.0` could survive an upgrade or restore | Fixed on install, update, and restore; tested |
| SEC-06 | Medium | HAOS host-key validation was permissive | Fixed with strict parser and fail-closed tests |
| SEC-07 | Medium | `sync_secret.js` was invoked without arguments | Fixed; secret synchronization tested |
| SEC-08 | Low | Diagnostics could include sensitive values | Fixed with redaction; tested |
| SEC-09 | Low | Historical commits contain a private IP and an internal hostname | Documented; see §9. Not a credential. |

There are **no unresolved Critical or High findings** in the current tree.

---

## 6. v1.0.0 migration safety

`cliproxy-manager update` (or re-running `install.sh`) on a v1.0.0 installation:

1. verifies the embedded bundle checksum;
2. snapshots the application tree;
3. swaps in the new tree and restarts;
4. rewrites a legacy `HOST=0.0.0.0`;
5. polls `/api/health`;
6. **only after health succeeds**, migrates the tunnel key and refreshes the sshd policy;
7. on failure, restores the previous tree, restarts, re-checks, and exits non-zero without touching SSH access.

The migration:

- removes `no-port-forwarding` from the managed tunnel key;
- preserves unrelated keys byte-for-byte;
- creates one timestamped backup;
- is idempotent;
- does not change OAuth credentials or the administrator password.

Evidence: `tests/test_upgrade_migration.sh` (15/15) and `tests/test_update_rollback.sh` (7/7).

---

## 7. Documentation sufficiency

An independent operator can, using only the repository:

| Task | Document |
| --- | --- |
| Check prerequisites and install the server component | [../docs/INSTALLATION.md](../docs/INSTALLATION.md) |
| Install and configure the HAOS add-on | [../docs/HAOS-ADDON.md](../docs/HAOS-ADDON.md) |
| Operate, back up, restore, rotate keys, uninstall | [../docs/OPERATIONS.md](../docs/OPERATIONS.md) |
| Understand trust boundaries and invariants | [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) |
| Upgrade from v1.0.0 and recover from failure | [../docs/UPGRADING.md](../docs/UPGRADING.md) |
| Diagnose common failures | [../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) |
| Understand the security policy and report issues | [../SECURITY.md](../SECURITY.md) |
| Contribute and run tests | [../CONTRIBUTING.md](../CONTRIBUTING.md) |
| Publish a release | [../docs/RELEASE-PROCESS.md](../docs/RELEASE-PROCESS.md) |

Relative links are checked by `tests/test_repo_hygiene.js`. The docs avoid real private addresses, credentials, and customer data; examples use `server.example.com` and documentation address ranges.

---

## 8. Licensing

- Project code: MIT ([../LICENSE](../LICENSE)).
- Bundled `yaml` dependency: ISC, with upstream notices retained in the package.
- Runtime and build-time components: listed in [../THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

No license incompatibility was identified for public distribution of the source repository. Publishing container images or packages would require a separate review; neither is performed by this release.

---

## 9. History inspection and privacy

- `gitleaks 8.30.1` scanned the working tree and all 4 commits: **no leaks found**.
- The current tree contains no private keys, GitHub/AWS/Slack tokens, private IPv4 addresses, or the legacy internal hostname. `tests/test_repo_hygiene.js` enforces this.
- Historical commits still contain:
  - a private RFC1918 address in the initial v1.0.0 commit;
  - an internal hostname in two later report commits.
- These are **non-credential, low-severity privacy artifacts**. They do not grant access to anything. No production system was accessed or modified during this audit.

Options for the owner, in order of preference:

1. **Accept and publish.** The addresses are internal, non-routable, and reveal no secret. This preserves the v1.0.0 tag and all history exactly.
2. **Rewrite history before making the repository public.** This is destructive, requires a force-push, and would change the commit that `v1.0.0` points to if the rewritten range includes it. It is **not** performed by this branch because release integrity forbids rewriting a published tag.

If option 2 is chosen, it must be done deliberately by the owner, with a fresh clone and a coordinated update of any published assets.

---

## 10. Release integrity

- `v1.0.0` tag and release assets are unmodified.
- No tag, release, package, or image was created for v1.0.1.
- No force-push or merge was performed.
- The branch is based on `fix/post-release-verification-v1.0.0` (`d4d8a72`), which is itself based on `main` (`6706176`).

---

## 11. Not verified (explicit limitations)

These are **not** claimed as working:

| Item | Why it is not verified |
| --- | --- |
| Native Debian 12/13 or Ubuntu install on real hardware or a real VM | Audit host is Windows; only simulated OS metadata and real scripts were exercised |
| Native ARM64 installation | No ARM64 hardware or emulator was available |
| Real Home Assistant OS Supervisor add-on build and Ingress panel | No HAOS instance was available; add-on structure, proxy logic, and parser were tested locally |
| Supervisor watchdog, Ingress token rotation, add-on backup/restore | Same reason |
| CLIProxyAPI Management API on `127.0.0.1:8317` | External component, not installed here; only configuration expectations are documented |
| systemd service lifecycle on a real Linux kernel | Simulated; no systemd on the audit host |
| Backup encryption at rest | Not implemented by design; documented as an operator responsibility |
| Multi-user roles, high availability, TLS termination for direct access | Out of scope |

The first install on a new platform should be treated as a change requiring a maintenance window and a backup.

---

## 12. Owner actions before changing visibility

Nothing in this branch changes repository visibility, tags, or releases. To proceed:

1. Review the diff on `release/public-readiness-v1.0.1`.
2. Either accept the historical private references (§9) or perform a deliberate, documented history rewrite.
3. Decide whether to merge the branch. This branch does **not** merge it.
4. After merge, tag and release `v1.0.1` only if the native-platform and real-HAOS checks in §11 can be completed, or explicitly accept them as documented limitations.
5. Change repository visibility manually in GitHub settings.
6. Enable private vulnerability reporting and branch protection on `main`.
7. Confirm the Home Assistant add-on repository URL resolves after visibility changes.

---

## 13. Acceptance statement

Within the environment and evidence available:

- no unresolved Critical or High finding remains;
- SSH forwarding restrictions were tested against a real OpenSSH daemon;
- v1.0.0 migration is automated, idempotent, and leaves SSH untouched on failed updates;
- loopback binding was verified with the real shipped application;
- icon dimensions, add-on metadata, version consistency, bundle checksum, and documentation links are validated by a repository test;
- licensing is clear for source distribution;
- history was inspected;
- limitations are stated rather than hidden.

Native Debian/Ubuntu, native ARM64, and real Home Assistant OS remain **not verified** and must be completed or explicitly accepted before a stable public announcement.
