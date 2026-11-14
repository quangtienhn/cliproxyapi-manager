# Publication Security Audit

**Scope:** source tree and history prepared for public visibility  
**Date:** 2026-11-12  
**Tools:** `gitleaks 8.30.1`, repository hygiene tests, manual review of scripts, SSH fixtures, and CI configuration

This audit covers what becomes visible if the repository is made public. It does not change visibility, tags, or releases.

---

## 1. Secret scanning

| Target | Command | Result |
| --- | --- | --- |
| Working tree | `gitleaks dir . --no-banner --redact` | no leaks found (~307 KB scanned) |
| Git history (4 commits) | `gitleaks detect --source . --no-banner --redact` | no leaks found (~129 KB scanned) |

`tests/test_repo_hygiene.js` additionally scans the current tree for:

- PEM/OpenSSH private key blocks;
- GitHub tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`);
- AWS access key IDs;
- Slack tokens;
- private IPv4 ranges;
- the legacy internal hostname;
- leftover `_tmp_` test scripts.

All current-tree checks pass.

### Historical artifacts

History still contains a private RFC1918 address (initial commit) and an internal hostname (two report commits). These are non-credential, low-severity privacy artifacts. No private key, token, password, or OAuth material was found. See [PUBLIC-RELEASE-READINESS.md](PUBLIC-RELEASE-READINESS.md) §9 for the decision record.

---

## 2. Credential handling in the product

- Management secrets and OAuth tokens are never accepted as command-line arguments.
- `manager.env` is `0640`, owned `root:cliproxyapi`.
- OAuth files are `0600`; backup roots are `0700`.
- Backups are **not** encrypted by the project. This is documented as an operator responsibility.
- `diagnostics.sh` redacts assignments matching secret/password/token/key patterns, bearer tokens, and GitHub tokens.
- The HAOS add-on logs only the **public** key and its fingerprint, never the private key.
- No secret is written to a release asset, commit message, or CI log by the project.

Residual risk: pattern-based redaction can miss a novel secret format. Operators are told to review diagnostics before sharing.

---

## 3. Network exposure

| Surface | Exposure | Evidence |
| --- | --- | --- |
| Account Manager `8320` | `127.0.0.1` only | Template, install/update/restore enforcement, real-service socket test |
| CLIProxyAPI management `8317` | `127.0.0.1`, `allow-remote: false` | Documented expectation; external component |
| HAOS add-on `8080` | Container-internal only | No `ports:` in `config.yaml`; Ingress only |
| SSH `22` | Administrator-managed; tunnel account restricted | Per-user `Match` policy and key options |
| Firewall | Not modified | No `iptables`, `nft`, or `ufw` calls in the installer |

The add-on publishes no host port. The installer never creates a WAN listener.

---

## 4. SSH restriction review

Generated `authorized_keys` entry:

```text
command="/bin/false",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320",permitlisten="127.0.0.1:1" <PUBLIC KEY>
```

Managed `sshd_config` block:

```text
Match User amtunnel
    AllowTcpForwarding local
    AllowStreamLocalForwarding no
    PermitOpen 127.0.0.1:8320
    PermitListen none
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForceCommand /bin/false
```

Notes:

- `permitlisten="none"` is invalid in `authorized_keys` on current OpenSSH and makes the key unusable; it is not used there.
- `PermitListen none` is valid in `sshd_config` and is the authoritative remote-forwarding control.
- The policy is appended to the main `sshd_config`, not `sshd_config.d/`, to avoid a trailing `Match` block changing the scope of later directives.
- Every edit is backed up, validated with `sshd -t`, and activated with a reload. A failed validation or reload restores the previous file.
- Real-daemon evidence: `tests/test_ssh_hardening.sh`, 20/20, including six remote-forwarding targets and four host-key failure modes.

Residual risk: an administrator who removes the managed block manually loses remote-forwarding protection, while `permitlisten` still limits the key. `cliproxy-manager check` warns when the block is missing.

---

## 5. Supply chain and CI

- GitHub Actions are pinned by full commit SHA: checkout v4.2.2, setup-node v4.4.0, gitleaks-action v2.3.9.
- Workflow permissions are read-only for contents; the secret-scan job additionally needs `pull-requests: read`.
- Concurrency cancels superseded runs.
- CI runs shellcheck (errors block), Node syntax checks, the full test suite, a separate real-sshd job, and gitleaks.
- `shellcheck` was **not installed** on the audit host, so it was not run locally. The CI job is configured to run it; a green CI run is still required before release.
- The embedded bundle is checksum-verified before extraction and contains only runtime files plus the ISC-licensed `yaml` dependency.
- The bundle checksum is asserted by the repository hygiene test.

Residual risk: Dependabot is configured but action updates still require review. A compromised upstream action pinned to a SHA is limited to that SHA's behavior; review before bumping.

---

## 6. Lifecycle and failure safety

- Update: checksum → snapshot → staged `node --check` → atomic swap → loopback rewrite → restart → health poll → post-success SSH migration; failure triggers restore and non-zero exit.
- Restore: per-file SHA-256 verification → pre-restore safety copy → restore → loopback rewrite → restart. SSH files are not restored.
- Uninstall: preserves data and SSH by default; `--purge-data` removes managed key and policy but keeps backups.
- Backup: includes config, CLIProxyAPI config, OAuth files, tunnel key, managed sshd policy, unit, metadata, and checksums, with restrictive modes.

Evidence: `tests/test_update_rollback.sh` (7/7), `tests/test_upgrade_migration.sh` (15/15), `tests/test_failure_recovery.sh` (4/4), `tests/test_sshd_policy.sh` (15/15).

Residual risk: backups are plaintext. If the backup medium is exposed, provider credentials are exposed. This is documented prominently.

---

## 7. Documentation and metadata review

- Public docs use `server.example.com` and documentation address ranges, not real hosts.
- Issue and pull-request templates explicitly forbid secrets and private data.
- `SECURITY.md` provides private reporting guidance.
- `THIRD-PARTY-NOTICES.md` lists bundled and runtime licenses.
- The add-on icon and logo are original generated artwork; the generator is committed.
- `repository.yaml` provides valid add-on repository metadata.

---

## 8. Findings summary

| Category | Severity | Status |
| --- | --- | --- |
| Secret leakage in current tree | None | Pass |
| Secret leakage in history | None | Pass (gitleaks) |
| Historical private IP/hostname | Low (privacy) | Documented; owner decision |
| Loopback enforcement | — | Pass with real app |
| SSH forwarding restrictions | — | Pass against real sshd |
| Update/rollback safety | — | Pass with regression suite |
| Backup confidentiality | Medium (design) | Documented; operator responsibility |
| Native platform verification | — | Not verified; documented |

No unresolved Critical or High security finding was identified.

---

## 9. Recommended owner actions

1. Enable GitHub private vulnerability reporting.
2. Enable branch protection on `main` and require the CI checks.
3. Keep the gitleaks workflow enabled for pushes and pull requests.
4. Decide whether to accept or rewrite the historical private references before making the repository public.
5. Do not publish Docker images or packages as part of this source release.
6. Re-run `bash tests/run_all.sh` and `gitleaks detect --source .` immediately before changing visibility.
