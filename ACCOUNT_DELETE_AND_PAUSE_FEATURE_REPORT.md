# Account Deletion Fix & Per-Account Pause/Resume — Completion Report

**Date:** 2026-11-17
**Status:** Implementation and local automated verification complete. **No commit, no push, no deployment, no production access.**
**Scope:** Source code only, in isolated test data.

---

## 0. Workspace verification (important)

| Item | Verified value |
| --- | --- |
| Repository requested by the task | `quangtienhn/cliproxyapi-manager` at `D:\Workspace\CLIProxyAPI-Manager` |
| Actual content of that repository | **Installer / add-on / docs / embedded runtime bundles only.** It has no `src/`, `public/`, or app test suite. |
| Actual Account Manager application source | `D:\Workspace\CLI2API\src\`, `public\`, `tests\` (package `cliproxyapi-account-manager`). Not a Git repository. |
| Source identity check | `src/server.js`, `src/auth_store.js`, `public/app.js`, `public/index.html`, `public/style.css` are byte-identical to the runtime files inside `server-installer/embedded/cliproxyapi-account-manager-v1.0.2.tar.gz` of the requested repository. Only `package.json` differs (bundle is labelled 1.0.1). |
| Wrong-project guard | No file in `chenyme-grok2api`, `Grok2API-HAOS-App`, TX3 tooling, or any other repository was modified. |

**Decision:** the fix was applied to the real application source at `D:\Workspace\CLI2API`. The installer repository was left untouched because it does not contain editable app source. Rebuilding the embedded runtime bundle is listed as a post-approval deployment step in section D.

---

## 0.1 Current data flow (before the change)

```text
Browser (public/app.js)
  │  deleteAccount(filename) → DELETE /api/accounts?filename=<encoded>
  ▼
HAOS Ingress proxy.mjs        (prefix stripped, query string preserved)
  ▼
src/server.js                 validateAuthFilename(filename)
  │                                  │ reject → 400 "Valid filename parameter is required."
  ▼                                  ▼
LocalAuthStore.deleteAccount()
  ├─ validate filename
  ├─ prefix whitelist
  └─ fs.unlinkSync(AUTH_DIR/<file>)
  ▼
CLIProxyAPI file watcher → hot reload of its credential set
  ▼
CLIProxyAPI account selection for /v1/* requests
```

New state-control flow added in this work:

```text
Browser Pause/Resume button
  ▼
POST /api/accounts/pause|resume?filename=<encoded>   (CSRF protected)
  ▼
Account Manager
  ├─ validate + resolve auth path + verify credential file
  ├─ serialize concurrent state changes
  ├─ PATCH /v8/management/credentials/status
  │    body: {"name":"<auth file>","disabled":true|false}
  │    auth: Bearer <CLIPROXYAPI_MANAGEMENT_KEY> (never logged)
  ▼
CLIProxyAPI writes metadata.disabled into the auth file (0600)
  ▼
CLIProxyAPI watcher reloads → paused credential not selected for new requests
  ▼
Account Manager re-reads metadata.disabled and returns the persisted state
```

---

## A. Delete bug

### A.1 Root cause

CLIProxyAPI stores Gemini (Antigravity) credentials as `antigravity-<email>.json` — verified from upstream `internal/auth/antigravity/filename.go`. Those filenames contain `@` (and may contain `+`).

`src/auth_store.js :: validateAuthFilename()` used:

```js
/^[a-zA-Z0-9_\-\.]+$/
```

That regex rejects `@`, so `src/server.js :: DELETE /api/accounts` returned **400 `Valid filename parameter is required.`** before `LocalAuthStore.deleteAccount()` was ever called. The reported error text therefore came from the *validation gate*, not from the unlink operation.

Two secondary defects existed behind it:
1. The prefix whitelist in `deleteAccount()` omitted `gemini-` (and several other providers).
2. Delete unlinked the file directly without consulting CLIProxyAPI and created a backup even for a missing/invalid target.

### A.2 Fix

| File | Change |
| --- | --- |
| `src/auth_store.js` | Replaced the regex with a single-safe-segment validator that allows `A-Z a-z 0-9 @ + . _ -`, requires `.json`, caps length at 254 chars, and rejects `..`, leading dots, control characters, `/` and `\`. No bypass, no hardcoded filename. |
| `src/auth_store.js` | Added `resolveAuthPath()` — every untrusted filename becomes an absolute path only if `path.dirname(resolved) === path.resolve(authDir)`. |
| `src/auth_store.js` | Added `assertManagedCredential()` / `getManagedAccountPath()`: known provider prefix, regular file (symlinks rejected), parseable JSON with credential-like shape. Unknown formats are rejected before any filesystem lookup. |
| `src/auth_store.js` | `deleteAccount()` now throws typed `AccountStoreError` with codes `INVALID_FILENAME`, `ACCOUNT_NOT_FOUND`, `NOT_A_CREDENTIAL_FILE`, `DELETE_FAILED`. |
| `src/server.js` | DELETE validates and confirms existence **before** `createBackup()`; maps typed errors to 400 / 404 / 500 with clear messages; logs only the filename, never credential content. |
| `src/auth_store.js` | Prefix list extended with `gemini-`, `grok-`, `vertex-`, `kimi-`, `devin-`, `meta-` while keeping Codex/xAI/Claude/Antigravity. |

Path traversal, shell metacharacters, non-JSON files, unrelated JSON config files, symlinks and files outside `AUTH_DIR` remain blocked. Deleting a `Paused` account works through the same path.

### A.3 Delete test results

All tests are in `tests/account_status_and_delete.test.js` and use synthetic credentials in `mkdtemp` directories.

| Case | Result |
| --- | --- |
| Gemini/Antigravity `antigravity-synthetic.user@example.com.json` deleted | **PASS** |
| Other providers (Codex, xAI) deleted | **PASS** |
| Missing filename → 400 | **PASS** |
| Invalid filenames (`../etc/passwd`, `; rm -rf /`, `.txt`, backslash, hidden) → 400 | **PASS** |
| Non-existent account → 404, no backup created | **PASS** |
| Path traversal cannot delete a file outside `authDir` | **PASS** |
| Paused account can still be deleted | **PASS** |
| Other accounts untouched after a single delete | **PASS** |

---

## B. Pause / Resume

### B.1 Architecture decision

CLIProxyAPI v8.0.61 (production version, tag `681ce41`) exposes:

```http
PATCH /v8/management/credentials/status
Authorization: Bearer <management-key>
Content-Type: application/json

{"name":"<auth file>","disabled":true}
```

Verified upstream:
- `internal/api/server_management_v8.go` registers the route.
- `internal/api/handlers/management/auth_files_fields.go :: PatchAuthFileStatus` requires `name` and boolean `disabled`, returns 404 for unknown files, and calls `authManager.Modify`.
- `applyAuthDisabledState()` sets `Disabled`, `Status`, and `metadata.disabled`.
- `sdk/auth/filestore.go` persists `metadata.disabled` and skips recreating a disabled credential file.
- `sdk/cliproxy/auth/conductor_lifecycle.go :: Modify` persists the change and updates the runtime scheduler, so selection for new requests excludes disabled credentials.

Using this native mechanism is safer than renaming/moving auth files or maintaining a parallel metadata store: it cannot drift from CLIProxyAPI, it survives restart/upgrade, and it does not require reading or rewriting tokens by Account Manager.

A separate Account Manager metadata file was **rejected** because it would not by itself stop CLIProxyAPI from selecting the account, and would need a custom exclusion layer plus extra reload logic.

### B.2 State storage and backward compatibility

| Requirement | Implementation |
| --- | --- |
| States | `active`, `paused`; also `unknown` for malformed metadata |
| Persistent | Flag lives in the existing auth file as `metadata.disabled`, written by CLIProxyAPI |
| Old accounts | No `metadata.disabled` → `active`; no migration needed |
| No secrets in metadata | Account Manager reads only the boolean; it writes no metadata itself |
| Invalid metadata | Non-boolean flag → `state: 'unknown'` + `metadataError`, never treated as paused |
| Restart/upgrade | State is in the auth file, so a restarted Account Manager reads the same value |
| Concurrency | Operations serialized per server instance; CLIProxyAPI has its own per-auth lock |

### B.3 How a paused account is actually prevented from being used

Account Manager does **not** merely hide the row or change a colour:
- CLIProxyAPI receives `disabled: true` and persists it.
- CLIProxyAPI's credential selector excludes disabled auths; the mock used in tests reproduces that selection rule and the test asserts a paused credential is not chosen while another Active credential still serves the request.
- The `Active Accounts` counter excludes paused and expired/corrupted accounts.

**In-flight requests:** not cancelled. CLIProxyAPI's native disable affects credential selection; a request already bound to a credential may finish. This is documented in the UI confirmation and in `docs/OPERATIONS.md`.

### B.4 Resume

Resume sends `disabled: false`, then re-reads the file. If the credential is missing or the management API fails, the request returns 404/502/503/504, the UI shows the error, and the stored credential is unchanged. No re-login is required when tokens remain valid.

### B.5 Files changed

| Path | Purpose |
| --- | --- |
| `src/account_status.js` | **New.** Management API client, error types, upstream-text sanitization, timeout. |
| `src/auth_store.js` | Filename validation, path containment, credential checks, typed errors, pause-state parsing. |
| `src/server.js` | Improved DELETE; new `POST /api/accounts/pause` and `/resume`; state counters; serialized state changes; safe error mapping. |
| `public/app.js` | Status badge (`Active` / `Paused` / `Expired` / `Corrupted`), Pause/Resume buttons, confirmation, counters, result alerts. |
| `public/index.html` | `Paused Accounts` stat card. |
| `tests/account_status_and_delete.test.js` | **New.** 19 automated tests. |
| `tests/mock_cliproxyapi.js` | Mock now supports `PATCH /credentials/status`, persists the flag, and honours it in request selection. |
| `CHANGELOG.md`, `docs/OPERATIONS.md`, `docs/ARCHITECTURE.md` | User/operator documentation. |

### B.6 Pause/Resume test results

| Case | Result |
| --- | --- |
| Active → Paused, `metadata.disabled=true`, tokens byte-identical | **PASS** |
| Paused → Active, flag cleared, tokens byte-identical | **PASS** |
| Pause non-existent account → 404 | **PASS** |
| Resume non-existent account → 404 | **PASS** |
| Pause does not delete auth file | **PASS** |
| State survives restart (new store instance, same dir) | **PASS** |
| Legacy file without metadata defaults to Active | **PASS** |
| Invalid `disabled` flag reported as `unknown`, not paused | **PASS** |
| Paused credential not selected for new request; another Active still works | **PASS** |
| Dashboard counters: active 3→2, paused 0→1 | **PASS** |
| Resume with simulated management failure → 502, credential unchanged | **PASS** |
| Missing management key → 503, state unchanged | **PASS** |
| Concurrent pause+resume → no corrupted metadata; final state consistent | **PASS** |

---

## C. Regression and security

### C.1 Test execution — real results

| Command | Result |
| --- | --- |
| `node --test tests/account_status_and_delete.test.js` | **PASS — 19/19** |
| `npm test` (`node --test tests/*.test.js`) | **PASS — 37/37** |
| `bash tests/test_bash_parser.sh` | **PASS** |
| `bash tests/test_phase3_simulation.sh` | **PASS** |
| `bash tests/test_rollback_hardening.sh` | **PASS** |
| `bash tests/verify_extracted_archive.sh` | **PASS** |
| `node --check` on all changed JS files | **PASS** |

No test result was fabricated; all commands were executed locally on 2026-11-17.

### C.2 Not tested / limitations

| Item | Status |
| --- | --- |
| Real CLIProxyAPI v8.0.61 running on TX3 | **NOT TESTED** — production access prohibited |
| Real Home Assistant Ingress round-trip for the new endpoints | **NOT TESTED** — no HAOS instance |
| Native Debian ARM64 service lifecycle | **NOT TESTED** in this environment |
| ESLint / TypeScript type-check | **NOT TESTED** — no lint or TS configuration exists in the project |
| shellcheck | **NOT TESTED** — no shell source was changed; binary not required |
| Full-workspace gitleaks scan | 145 pre-existing findings in unrelated legacy files / `node_modules`; **not triaged** (out of scope). Scan of the 10 changed files: **no leaks found**. |
| Effect on a request already in flight at Pause time | **NOT TESTED** against real CLIProxyAPI; documented as "may finish" |

### C.3 Credential safety

- No access token, refresh token, cookie, or private key was written to source, logs, or the report.
- All fixtures are synthetic strings containing `synthetic_...` and live only in temporary directories removed by test cleanup.
- Audit log entries contain event type, filename, IP, and username only.
- Upstream error text passed to the UI is sanitized (Bearer tokens and long opaque strings redacted, max 180 chars).
- The management key is read from config, sent only in an Authorization header, and never logged or returned to the browser.
- No auth file from a real server was read, modified, moved, or deleted.
- No commit or push was performed. The installer repository's pre-existing untracked files (`SSH_TUNNEL_FIX_REPORT.md`, `scripts/`) were not touched.

### C.4 Backward compatibility

- Existing `GET /api/accounts` response keeps `total` and `accounts`; `active` and `paused` are additive.
- Existing account objects keep `status`, `expiresAt`, `lastRefresh`, `emailMasked`, `hasRefreshToken`; `state`, `disabled` and optional `metadataError` are additive.
- Existing endpoints and OAuth flows are unchanged.
- Existing tests (including the strict-deployment simulation that expects the old generic rejection message for unknown filenames) still pass.
- Requires `CLIPROXYAPI_MANAGEMENT_KEY` to be present for Pause/Resume. Delete continues to work without it.

### C.5 Residual risks

1. CLIProxyAPI treats persistence failures on `Modify` as non-fatal (logs a warning). Account Manager's post-change read-back will then return 502 even though the in-memory state changed. This is a deliberate fail-closed behavior; the operator can verify with `GET /v8/management/credentials`.
2. If a future CLIProxyAPI version changes the status endpoint contract, the 5-second timeout and typed errors stop the feature cleanly; Delete is unaffected.
3. Filenames using characters outside `[A-Za-z0-9@+._-]` (unusual internationalized emails) are rejected by validation. They remain visible in the list but cannot be managed through these endpoints until the allow-list is extended.
4. The embedded runtime bundle in the installer repository has **not** been rebuilt. Until that is done (section D), deploying from that repository would not contain this fix.

---

## D. Deployment (after owner approval — not performed)

### D.1 Changes that must be deployed

1. Replace `src/server.js`, `src/auth_store.js`, `public/app.js`, `public/index.html` with the modified versions.
2. Add `src/account_status.js`.
3. Ensure `manager.env` contains a valid `CLIPROXYAPI_MANAGEMENT_KEY` (the existing installer/sync mechanism can populate it). Pause/Resume returns 503 without it; Delete is unaffected.
4. Rebuild the runtime-only bundle for the installer repository and update its checksum and the installer's referenced version:

   ```bash
   cd /path/to/cliproxyapi-account-manager
   # stage only LICENSE, package.json, package-lock.json, public/, src/
   tar --sort=name --owner=0 --group=0 --numeric-owner -czf \
     cliproxyapi-account-manager-v<NEW>.tar.gz .
   cd <installer-repo>/server-installer/embedded
   sha256sum cliproxyapi-account-manager-v<NEW>.tar.gz > SHA256SUMS-v<NEW>.txt
   ```

   Then update the bundle path/version in `install.sh`, `update.sh`, `backup.sh`, the installer `CHANGELOG.md`, and regenerate the repository-root `SHA256SUMS.txt`. **Do not move or force-push the v1.0.0 tag.**

### D.2 Safe update on TX3

1. Take a full backup first:
   ```bash
   sudo cliproxy-manager backup
   sudo tar -C /var/backups/cliproxyapi-account-manager -czf \
     /root/pre-account-manager-fix-$(date +%F).tar.gz .
   ```
   Store the archive off-host; it contains OAuth credentials.
2. On a clone of the repository, run `bash tests/run_all.sh`-equivalent app tests (`npm test`) before deploying.
3. Update with the standard workflow:
   ```bash
   cd cliproxyapi-account-manager-easy-installer/server-installer
   sudo bash update.sh
   ```
   The updater verifies the bundle checksum, snapshots the current application tree, enforces loopback, and rolls back automatically if `/api/health` fails. SSH migrations run only after a healthy start.
4. Confirm:
   ```bash
   sudo cliproxy-manager check
   sudo ss -ltnp | grep ':8320'
   curl -s http://127.0.0.1:8320/api/health
   ```

### D.3 Functional verification after deployment

1. Open the dashboard through the HAOS Ingress panel.
2. For a Gemini/Antigravity account, confirm the `Auth File` column shows `antigravity-<email>.json` and click **Delete**. The account should be removed with a success message; other accounts remain.
3. Pick another account, click **Pause**, accept the confirmation. Confirm:
   - badge becomes `Paused`;
   - `Active Accounts` decreases by 1 and `Paused Accounts` increases by 1;
   - the auth file still exists and contains its original `access_token` / `refresh_token` (compare by fingerprint only — do not print values);
   - CLIProxyAPI no longer selects it for a new request.
4. Click **Resume**. Confirm the badge returns to `Active` without re-authentication.
5. Restart the Account Manager service and confirm the Paused state is still shown.

### D.4 Backup and rollback

- Backups created by `cliproxy-manager backup` are plaintext; store them encrypted and off-host.
- If the update fails health checks, `update.sh` restores the previous tree automatically. Verify with `cliproxy-manager check`.
- For manual rollback, stop the service, restore the application tree from the update snapshot (`/var/backups/cliproxyapi-account-manager/snapshot_*`), restart, and re-run `curl http://127.0.0.1:8320/api/health`.
- Auth files are **not** modified by Delete's rollback path; a deleted credential is restored only by copying it back from the pre-deletion `auths.bak.*` directory created by `createBackup()`.
- Rollback of a Pause is simply **Resume**; no file restore is needed.

### D.5 Approval boundary

None of the above was executed. TX3, Home Assistant OS, production auth files, repository visibility, tags, releases, and Git history remain unchanged. No commit or push was made in either workspace.
