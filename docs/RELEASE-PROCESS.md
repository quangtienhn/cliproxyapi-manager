# Release Process

This document describes how to validate and publish a release. It is written for maintainers and assumes write access to the repository.

The process is deliberately conservative: no force-pushes, no rewriting published tags, and no release until every required check has evidence.

## 1. Branching

1. Branch from `main`:

   ```bash
   git checkout main
   git pull --ff-only
   git checkout -b release/<version>
   ```

2. Make changes in focused commits with descriptive messages.
3. Push the branch and open a pull request. Do not merge directly to `main`.

## 2. Version consistency

Update the version in all of these places:

| File | Field |
| --- | --- |
| `haos-addon/config.yaml` | `version:` |
| `haos-addon/CHANGELOG.md` | new section |
| `CHANGELOG.md` | new section |
| `server-installer/embedded/package.json` (inside bundle) | `version` |
| `server-installer/embedded/package-lock.json` (inside bundle) | `version`, `packages[""].version` |
| Bundle filename and `SHA256SUMS-v1.0.3.txt` | version in name |
| `server-installer/install.sh`, `update.sh`, `backup.sh` | version banners / bundle path (when the version changes) |

The repository hygiene test asserts that the add-on version, changelog top entry, bundle filename, and checksum filename agree.

## 3. Build the embedded bundle

The bundle is runtime-only. It must contain:

```text
LICENSE
package.json
package-lock.json
public/
src/
```

It must not contain `deploy/`, `docs/`, `tests/`, `README.md`, `CHANGELOG.md`, `.env.example`, `.gitignore`, or `SHA256SUMS.txt`.

Build reproducibly:

```bash
cd /path/to/cliproxyapi-account-manager
# stage the runtime tree, set package versions, normalize mtimes
tar --sort=name --owner=0 --group=0 --numeric-owner -czf \
  cliproxyapi-account-manager-v1.0.3.tar.gz .
```

Place it at:

```text
server-installer/embedded/cliproxyapi-account-manager-v1.0.3.tar.gz
```

Regenerate the checksum:

```bash
cd server-installer/embedded
sha256sum cliproxyapi-account-manager-v1.0.3.tar.gz > SHA256SUMS-v1.0.3.txt
```

The checksum line must be `HASH *filename` or `HASH  filename`; the installer reads the first field.

Also rebuild `yaml-dependency.tar.gz` if the dependency changed. It is extracted into the application root and provides `node_modules/yaml`.

## 4. Regenerate repository checksums

At the repository root:

```bash
find . -path ./.git -prune -o -path ./node_modules -prune -o -type f -print0 \
  | sort -z \
  | xargs -0 sha256sum > SHA256SUMS.txt
```

Exclude release archives and local artifacts that are not tracked. Verify:

```bash
sha256sum -c SHA256SUMS.txt --ignore-missing
```

## 5. Run the full test suite

From the repository root:

```bash
bash tests/unit/test_installer_core.sh
node tests/unit/test_haos_proxy.js
bash tests/integration/test_lifecycle.sh
bash tests/test_cross_platform_matrix.sh
bash tests/test_failure_recovery.sh
node tests/test_loopback_bind.js
node tests/test_haos_proxy_live.js
bash tests/test_migration_logic.sh
bash tests/test_sshd_policy.sh
bash tests/test_update_rollback.sh
bash tests/test_upgrade_migration.sh
node tests/test_hostkey_parser.js
node tests/test_real_service_loopback.js
bash tests/test_ssh_hardening.sh   # requires local sshd fixtures; SKIP otherwise
bash tests/test_repo_hygiene.sh
```

The SSH hardening test needs a local `sshd`, client key, and host key. On CI, install OpenSSH and set:

```bash
export SSHD_BIN=/usr/sbin/sshd
export SSH_BIN=ssh
export SSHD_CLIENT_KEY=/path/to/client_key
export SSHD_HOST_KEY=/path/to/host_key
export SSHD_USER=runner
export SSHD_PORT=2222
```

If fixtures are missing, the test prints `SKIP` and exits 0. A skipped native test is not evidence that SSH hardening works; record it as not run.

The repository hygiene test also scans the current tree for private IPv4 ranges, the legacy hostname used during development, secrets, invalid icon dimensions, and broken relative documentation links.

## 6. Manual verification required before a release

These cannot be replaced by unit tests:

- [ ] Install on a **real Debian 12 AMD64** host or VM.
- [ ] Install on a **real Debian 12/13 ARM64** host or VM.
- [ ] Install on a **real Ubuntu 24.04 AMD64** host or VM.
- [ ] Reboot the server and confirm the service and tunnel recover.
- [ ] Install the add-on in a **real Home Assistant OS** Supervisor and open the Ingress panel.
- [ ] Confirm no host port appears in the add-on network settings.
- [ ] Confirm `ss -ltnp` shows `127.0.0.1:8320` only.
- [ ] Upgrade a real v1.0.0 installation and confirm the tunnel works afterward.
- [ ] Run a backup, wipe a test VM, restore, and confirm OAuth data and admin login survive.
- [ ] Rotate the tunnel key and confirm the old key stops working.

Record the platform, OS version, kernel, architecture, date, and exact commands in a report. Label simulations as simulations.

## 7. Security gate

- [ ] No secrets in the tree or history (`gitleaks detect --source . --log-opts=--all`).
- [ ] No private hostnames, IPs, tokens, or customer data in the current tree.
- [ ] `shellcheck` clean for all shell scripts, or every finding documented.
- [ ] `node --check` passes for all bundled JS.
- [ ] `sshd -t` passes for the generated policy.
- [ ] `HOST=127.0.0.1` in the template and no `0.0.0.0` fallback.
- [ ] No `no-port-forwarding` in generated keys.
- [ ] No `permitlisten="none"` (invalid on current OpenSSH).
- [ ] No `ports:` in add-on `config.yaml`.
- [ ] License and third-party notices updated.

## 8. Tag and release

Only after the pull request is reviewed and merged:

```bash
git checkout main
git pull --ff-only
git tag -a v1.0.3 -m "v1.0.3"
git push origin v1.0.3
```

Do not move or force-push an existing tag. If a release artifact is wrong, publish a new patch version.

Create the GitHub release from the tag and attach:

- `cliproxyapi-manager-v1.0.3.tar.gz`
- `.sha256` file

Release notes must include:

- the v1.0.0 tunnel defect and how it is fixed;
- the remote-forwarding hardening change;
- migration behavior and backup expectations;
- supported platforms and explicit "not verified" items;
- checksums.

## 9. Post-release

- [ ] Verify the release assets download and checksums match.
- [ ] Verify the add-on store sees the new version.
- [ ] Update `CHANGELOG.md` links if needed.
- [ ] Announce with the security-relevant changes first.
- [ ] Keep the previous release available for rollback.

## 10. What not to do

- Do not force-push `main` or a release tag.
- Do not rewrite published history to remove old private references without a coordinated, documented migration; rotate anything exposed instead.
- Do not publish Docker images or packages from this repository unless a separate release process exists.
- Do not claim native platform coverage based on simulation.
- Do not merge a release branch with failing required checks.

## 11. Release checklist summary

```text
[ ] version bumped everywhere
[ ] bundle rebuilt and runtime-only
[ ] bundle SHA-256 regenerated
[ ] root SHA256SUMS.txt regenerated
[ ] full test suite run, output captured
[ ] real-platform matrix completed or marked not verified
[ ] HAOS add-on installed on real Supervisor
[ ] security gate clean
[ ] docs links valid
[ ] PR reviewed and merged
[ ] tag created without force
[ ] release assets uploaded and verified
```
