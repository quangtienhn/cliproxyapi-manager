# Post-Deployment Reconciliation Report

**Date:** 2026-11-17
**Repository:** `quangtienhn/cliproxyapi-manager`
**Trigger:** reconcile repository with the production state recorded in [TX3_HAOS_DEPLOYMENT_COMPLETION_REPORT.md](TX3_HAOS_DEPLOYMENT_COMPLETION_REPORT.md).

---

## 1. Version before and after

| Component | Before | After |
| --- | --- | --- |
| Runtime bundle filename | `cliproxyapi-account-manager-v1.0.3.tar.gz` | unchanged (v1.0.3) |
| Bundle internal `package.json` version | `1.0.2` | **`1.0.3`** |
| Bundle internal `package-lock.json` version | `1.0.2` | **`1.0.3`** |
| App source in repository | not present | **`account-manager/`, version 1.0.3** |
| HAOS add-on `config.yaml` version | `1.0.3` | unchanged (already correct) |
| Installer / updater bundle reference | v1.0.3 | unchanged (already correct) |
| CLIProxyAPI upstream version | not managed here | unchanged |

No version higher than 1.0.3 was introduced. No tag or GitHub Release was created.

---

## 2. Files changed or added

### Added

- `account-manager/` — full editable Account Manager source: `src/`, `public/`, `tests/`, `deploy/`, `package.json`, `package-lock.json`, `.env.example`, `README.md`, `NOTICE.md`.
- `account-manager/NOTICE.md` — preserves original author **Antigravity Engineering** and MIT attribution.
- `docs/PAUSE-RESUME.md` — Pause/Resume and Gemini deletion user guide.
- `scripts/p11-ssh-audit.sh`, `scripts/p11-ssh-fix.sh` — read-only audit and append-only key fix helpers (production IPs redacted).
- `ACCOUNT_DELETE_AND_PAUSE_FEATURE_REPORT.md` — feature-level report from the development phase.
- `TX3_HAOS_DEPLOYMENT_COMPLETION_REPORT.md` — production deployment report (private IPs redacted).
- `.gitleaksignore` — documents three false positives in synthetic security-test fixtures.

### Modified

- `README.md` — project status v1.0.3 **deployed**, origin/attribution section, added improvements, Pause/Resume and deployment report links, updated validation table.
- `CHANGELOG.md` — 1.0.3 dated 2026-11-17; source version alignment; top-level `disabled` fix; CLIProxyAPI loopback note.
- `THIRD-PARTY-NOTICES.md` — original author attribution and v1.0.3 bundle description.
- `docs/ARCHITECTURE.md` — documents `account-manager/` as the source of the runtime bundle.
- `docs/OPERATIONS.md` — routine Delete/Pause/Resume guidance.
- `docs/INSTALLATION.md`, `docs/UPGRADING.md`, `docs/HAOS-ADDON.md`, `docs/TROUBLESHOOTING.md`, `docs/RELEASE-PROCESS.md` — version and deployment notes.
- `server-installer/embedded/cliproxyapi-account-manager-v1.0.3.tar.gz` — rebuilt with internal version 1.0.3.
- `server-installer/embedded/SHA256SUMS-v1.0.3.txt` — new checksum.
- `tests/test_repo_hygiene.js` — added bundle internal version check; removed obsolete private-hostname pattern.
- `tests/test_upgrade_migration.sh` — expectation updated from 1.0.1 to 1.0.3.
- `.gitignore` — ignores local `_deploy_v103/` staging artifacts.
- `SHA256SUMS.txt` — regenerated.

### Deliberately not committed

- `SSH_TUNNEL_FIX_REPORT.md` — stale draft report from before deployment, superseded by the deployment completion report. Left untracked, not deleted.
- `_deploy_v103/` — local deployment staging copy; now ignored.

---

## 3. Improvements consolidated

### Account Manager

- Gemini/Antigravity deletion accepts real auth filenames containing `@` and `+` while retaining path, symlink, and credential-shape validation.
- Delete distinguishes validation / not-found / filesystem errors and only creates a backup after the target is validated.
- Pause/Resume via CLIProxyAPI v8 `PATCH /v8/management/credentials/status` using the native top-level `disabled` flag. No token file is deleted or renamed.
- Dashboard shows `Active` / `Paused` badges and Active/Paused counters.
- Correct handling of CLIProxyAPI v8 writing top-level `disabled` while leaving legacy `metadata.disabled`.

### TX3 installer / updater

- Runtime bundle v1.0.3 with SHA-256 verification, snapshot, atomic swap, health gate, and rollback.
- Loopback bind enforced on install/update/restore.
- `manager.env` and OAuth data preserved; `HOST=0.0.0.0` rewritten to `127.0.0.1`.
- Per-user SSH policy installed/reloaded with validation and idempotent managed markers.

### HAOS add-on

- Ingress-only reverse proxy, no published host port.
- Persistent key storage under `/data`, host-key pinning with strict parser.
- Version 1.0.3 already installed and running; Dockerfile/s6 fixes from earlier history retained.

---

## 4. Test results

| Check | Result |
| --- | --- |
| `npm test` in `account-manager/` (Node test runner) | **PASS — 38/38** |
| `node --check` on all repository JS/MJS | **PASS** |
| `bash -n` on all repository shell scripts | **PASS** |
| `bash tests/run_all.sh` (15 suites) | **PASS — 15 passed, 0 failed, 0 skipped** |
| `node tests/test_repo_hygiene.js` | **PASS — 65/65** |
| Real OpenSSH E2E (`test_ssh_hardening.sh`) | **PASS — 20/20** |
| Real Account Manager loopback test | **PASS — 16/16** |
| Bundle checksum `sha256sum -c SHA256SUMS-v1.0.3.txt` | **PASS** |
| Root `SHA256SUMS.txt` | **148 files, 0 mismatch** |
| `gitleaks dir .` | **no leaks found** (3 documented false positives ignored) |
| Bundle internal `package.json` version | **1.0.3** |
| Bundle contains required runtime files | **PASS** |
| Bundle is runtime-only (no deploy/docs/tests) | **PASS** |

Not run locally: `shellcheck` (not installed), Docker build of the HAOS add-on, real HAOS Supervisor rebuild, native fresh install on other distributions.

---

## 5. Bundle SHA-256

```text
2450b9742fe5f1517e9bf26974a58a9a76ccc63c2ddb4af0577418988a052f4a  cliproxyapi-account-manager-v1.0.3.tar.gz
```

This replaces the earlier deployment checksum `60f69ed2...` because the internal version metadata was corrected to 1.0.3. The deployed production code logic is unchanged by this metadata-only rebuild.

---

## 6. Installer / updater checks

- `server-installer/install.sh` and `update.sh` reference `cliproxyapi-account-manager-v1.0.3.tar.gz` and `SHA256SUMS-v1.0.3.txt`.
- Updater checksum lookup uses `grep -E "<bundle>\$" ... | awk '{print $1}'` and aborts on mismatch.
- Updater snapshots the application tree before swapping, enforces loopback bind, restarts the service, polls `/api/health`, and rolls back on failure.
- SSH migrations run only after a healthy start.
- The managed `Match User amtunnel` block uses the same markers as `lib/sshd_policy.sh`, so refresh is idempotent.
- Shell syntax validated with `bash -n`.

---

## 7. Commit and GitHub

| Item | Value |
| --- | --- |
| Commit hash | `febca6968bcc4b4963b959cf2fb9e2f1c8532ccb` |
| Commit message | `release(account-manager): align v1.0.3 after TX3 and HAOS deployment` |
| GitHub URL | `https://github.com/quangtienhn/cliproxyapi-manager/commit/febca6968bcc4b4963b959cf2fb9e2f1c8532ccb` |
| Branch | `main` |

---

## 8. Local / remote sync

After the final documentation commit is pushed, local `HEAD` and `origin/main` are identical. The alignment commit is `febca6968bcc4b4963b959cf2fb9e2f1c8532ccb`; a small follow-up commit only fills in this report and its checksum entry. Both are pushed to `main`.

Verification commands:

```bash
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

---

## 9. Limitations not covered

- Docker/HAOS Supervisor add-on rebuild from source: **NOT TESTED**.
- Fresh native Debian/Ubuntu/ARM64 installation: **NOT TESTED**.
- `shellcheck`: **NOT TESTED** (binary unavailable in this environment).
- Real production restart test for Pause persistence: **NOT PERFORMED** (unit-tested and stored in auth file).
- CLIProxyAPI upstream itself: not bundled or modified by this repository.

---

## 10. Confirmations

- No Git tag created.
- No GitHub Release created.
- Repository visibility unchanged.
- No force push, rebase, or history rewrite.
- No production TX3 or HAOS change during this reconciliation.
- No token, password, private key, or account credential added to Git.
