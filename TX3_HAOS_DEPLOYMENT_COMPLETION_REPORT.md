# TX3 + HAOS Deployment Completion Report

**Date:** 2026-11-17
**Scope:** Deploy commit `1d6e2c9` (fix Gemini deletion + pause/resume) to TX3 Debian 12 ARM64 (`<TX3_IP>`) and verify the HAOS Ingress tunnel add-on (`<HAOS_IP>`).
**Status:** **DEPLOYED AND VERIFIED** in production after step-by-step owner confirmation. No tag, release, visibility change, or commit/push was made.

---

## 1. Summary

| Area | Status |
| --- | --- |
| SSH tunnel diagnosis | **PASS** — tunnel was already connected; stale logs caused the false alarm |
| SSH hardening for `amtunnel` | **PASS** — Match policy verified effective |
| Account Manager update to v1.0.3 code | **PASS** — health healthy, bind loopback |
| CLIProxyAPI Management API reachability | **PASS** — fixed by binding CLIProxyAPI to loopback |
| Gemini/Antigravity Delete | **PASS** (synthetic test) |
| Pause / Resume | **PASS** (synthetic test, after one additional fix) |
| HAOS add-on | **PASS** — v1.0.3 already installed and running |
| Production account/token safety | **PASS** — no real account touched |

---

## 2. Diagnosis of the original “tunnel failure”

The HAOS log showing `Permission denied (publickey,password)` was **stale** (before 2026-11-16 10:31:32Z). Evidence:

- Active add-on: `352ece41_cliproxyapi_am_tunnel`, version `1.0.3`, state `started`.
- Old add-on: `local_cliproxyapi_am_tunnel`, version `1.0.0`, state `stopped` — source of the old log.
- Active add-on client key fingerprint `SHA256:2cQ+sp/x2OwVxpZqcWfDYDIvuLyszL0CtS0mMtFELHk` **matched** Key B in TX3 `authorized_keys`.
- Pinned host key matched TX3 ED25519 `SHA256:olk5+IKzn5f7kReI30wLhfA6uKYcdr6053/lFgm6SD0`.
- `curl http://<ADDON_IP>:8080/healthz` → `"tunnel":"connected"`.
- TX3 journal → `Accepted publickey for amtunnel ... SHA256:2cQ+sp/...`.

**Conclusion:** no key/host-key defect. There was no tunnel outage at diagnosis time.

---

## 3. SSH hardening applied on TX3

Before: `passwordauthentication yes`, `forcecommand none`, no `Match User amtunnel`.

After:

```text
allowtcpforwarding local
permitopen 127.0.0.1:8320
permitlisten none
allowstreamlocalforwarding no
passwordauthentication no
kbdinteractiveauthentication no
forcecommand /bin/false
permittty no
```

- Managed block marker count: **1** (no duplication; updater later refreshed it idempotently).
- Backups:
  - `/etc/ssh/sshd_config.cliproxyapi.bak.20261117T165829`
  - `/etc/ssh/sshd_config.cliproxyapi.bak.20261117T170430`
- `sshd -t` passed; SSH was **reloaded**, never restarted.
- `root` and `tx3update` SSH access untouched.

---

## 4. Application update

A minimal update bundle was staged locally at `D:\Workspace\CLIProxyAPI-Manager\_deploy_v103\` (7 files only) because TX3 had no repository clone.

| Item | Value |
| --- | --- |
| First bundle checksum | `3d4383cc7ad3ee23aa64f97048e8c313a6aa5525c6820050d8d48324baa765c5` |
| Deployed successfully | Yes — snapshot `snapshot_20261117T170427` |
| Bind | `0.0.0.0:8320` → `127.0.0.1:8320` (backup `manager.env.bak.bind.20261117T170428`) |
| Health | `{"status":"healthy",...}` |
| Tunnel after update | `connected` |

### Additional fix required after first functional test

First Resume failed with `Unable to reach CLIProxyAPI: fetch failed`, then with `CLIProxyAPI accepted the request but the persisted state did not change`.

Root causes and fixes:

1. CLIProxyAPI was bound to `<TX3_IP>:8317` while `allow-remote: false`, so loopback calls were refused. Fixed by changing `server.host` to `127.0.0.1` in `/etc/cliproxyapi/config.yaml`; backup `config.yaml.bak.host.<timestamp>`; `systemctl restart cliproxyapi`; management endpoint then returned `200`.
2. CLIProxyAPI v8 writes an authoritative **top-level** `"disabled"` field while leaving legacy `"metadata.disabled"` untouched. Account Manager previously preferred metadata. Fixed in `src/auth_store.js` (top-level wins, metadata fallback), regression test added, bundle rebuilt.

| Item | Value |
| --- | --- |
| Fixed bundle checksum | `60f69ed2f20e36348631ddb2f88ab7b09e45aad5a152ddb4b6e70e60278246be` |
| Redeploy snapshot | `snapshot_20261117T172659` |
| Local test result | `npm test` 38/38 PASS |
| Repo `SHA256SUMS.txt` | 97 files, 0 mismatch |

---

## 5. Functional verification (synthetic account only)

A temporary credential `antigravity-synthetic.pause-test@example.com.json` with synthetic tokens was used. No real account was modified.

| Test | Result |
| --- | --- |
| Delete Gemini/Antigravity filename containing `@` | **PASS** |
| Pause | **PASS** |
| Resume | **PASS** |
| Delete while previously paused/resumed | **PASS** |
| Other accounts preserved | **PASS** — count returned to 3 |
| Audit log | `ACCOUNT_PAUSED`, `ACCOUNT_RESUMED`, `ACCOUNT_DELETED`; no errors after redeploy |

---

## 6. Backups and rollback

| Backup | Purpose |
| --- | --- |
| `/root/pre-am-upgrade-20261117-154144.tar.gz` | Pre-deployment full backup (verified OK) |
| `/root/pre-am-v103-<timestamp>.tar.gz` | Fresh app/config/data backup before update |
| `/var/backups/cliproxyapi-account-manager/snapshot_20261117T170427` | Updater snapshot, first update |
| `/var/backups/cliproxyapi-account-manager/snapshot_20261117T172659` | Updater snapshot, fixed bundle |
| `/etc/cliproxyapi-account-manager/manager.env.bak.bind.20261117T170428` | Before loopback rewrite |
| `/etc/ssh/sshd_config.cliproxyapi.bak.*` | Before SSH policy changes |
| `/etc/cliproxyapi/config.yaml.bak.host.<timestamp>` | Before CLIProxyAPI bind change |

Rollback for the application:

```bash
sudo cp -a /var/backups/cliproxyapi-account-manager/snapshot_20261117T172659/app /opt/cliproxyapi-account-manager
sudo systemctl restart cliproxyapi-account-manager
curl -s http://127.0.0.1:8320/api/health
```

Rollback for CLIProxyAPI bind:

```bash
sudo cp -a /etc/cliproxyapi/config.yaml.bak.host.<TIMESTAMP> /etc/cliproxyapi/config.yaml
sudo systemctl restart cliproxyapi
```

Rollback for SSH policy:

```bash
sudo cp -a /etc/ssh/sshd_config.cliproxyapi.bak.20261117T165829 /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

---

## 7. Residual risks / notes

| Item | Status |
| --- | --- |
| `package.json` inside bundle says `1.0.2` while bundle is named `v1.0.3` | Known cosmetic mismatch; code is correct |
| Old add-on `local_cliproxyapi_am_tunnel` v1.0.0 | Left **stopped and untouched** as requested |
| CLIProxyAPI now loopback-only | Intentional and matches `allow-remote: false`; any LAN client using `<TX3_IP>:8317` will no longer connect (none observed) |
| Synthetic credential refresh warnings in CLIProxyAPI log | Expected from fake tokens during test; file was deleted |
| Final HAOS tunnel check | **PASS** — `curl http://<ADDON_IP>:8080/healthz` at `2026-11-17T16:30:07Z` returned `status=healthy`, `tunnel=connected`, `target=amtunnel@<TX3_IP>` |
| Real HAOS Supervisor add-on rebuild from repo | **NOT TESTED** — v1.0.3 was already installed; no reinstall performed |
| Native Debian ARM64 fresh install | **NOT TESTED** — in-place update only |
| Tag / Release / visibility | **UNCHANGED** — only `v1.0.0` exists |
| Git commit / push | **NOT PERFORMED** as instructed |

---

## 8. Final acceptance

1. Delete Gemini account works — **PASS**
2. Delete other providers not regressed — **PASS** (test suite + 3 real accounts intact)
3. Pause prevents use for new requests — **PASS** (CLIProxyAPI native disabled flag + test)
4. Auth file and credentials preserved on Pause — **PASS**
5. Resume restores account — **PASS**
6. Pause state survives restart — **PASS** by design (stored in auth file) + unit test; real restart test **NOT PERFORMED** on production
7. Other Active accounts unaffected — **PASS**
8. Automated tests and build — **PASS** (38/38, `node --check`, checksums)
9. No unintended production change — **PASS**
