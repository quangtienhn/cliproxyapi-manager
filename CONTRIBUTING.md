# Contributing

Thanks for taking the time to improve the project. This repository manages security-sensitive deployment code, so changes are reviewed with that in mind.

## Before you start

- Read [SECURITY.md](SECURITY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- For a security issue, do **not** open a public issue. Use GitHub private vulnerability reporting.
- Open an issue before a large change so the approach can be agreed first.
- By contributing, you agree that your contribution is licensed under the MIT License.

## Development setup

You need:

- Bash 4+ (Linux, macOS, WSL, or Git Bash for the shell-only tests);
- Node.js 18+;
- Python 3 only if you regenerate the icon;
- OpenSSH if you run the end-to-end tunnel tests;
- `shellcheck` and `gitleaks` for the full gate.

Clone:

```bash
git clone https://github.com/quangtienhn/cliproxyapi-account-manager-easy-installer.git
cd cliproxyapi-account-manager-easy-installer
```

No package installation is required at the repository root. The embedded `yaml` dependency is already packaged.

## Running tests

Fast suite:

```bash
bash tests/unit/test_installer_core.sh
node tests/unit/test_haos_proxy.js
bash tests/test_migration_logic.sh
bash tests/test_sshd_policy.sh
bash tests/test_update_rollback.sh
bash tests/test_upgrade_migration.sh
node tests/test_hostkey_parser.js
node tests/test_real_service_loopback.js
bash tests/test_repo_hygiene.sh
```

Lifecycle and live proxy tests:

```bash
bash tests/integration/test_lifecycle.sh
bash tests/test_failure_recovery.sh
node tests/test_loopback_bind.js
node tests/test_haos_proxy_live.js
bash tests/test_cross_platform_matrix.sh
```

SSH end-to-end (needs fixtures):

```bash
export SSHD_BIN=/usr/sbin/sshd
export SSHD_CLIENT_KEY=/path/to/client_key
export SSHD_HOST_KEY=/path/to/host_key
export SSHD_USER="$USER"
export SSHD_PORT=2222
bash tests/test_ssh_hardening.sh
```

The SSH test exits 0 with `SKIP` when fixtures are missing. Do not report a skip as a pass.

All tests must be green before a pull request is merged. If a test is flaky, fix the test or document why it is skipped; do not delete the assertion.

## Code style

### Shell

- Bash, `set -euo pipefail` in executables.
- Quote expansions: `"$var"`, `"${array[@]}"`.
- Prefer functions in `common/` or `server-installer/lib/` over duplication.
- Never evaluate untrusted input with `eval`.
- Never log secrets, private keys, or full OAuth payloads.
- Preserve unrelated lines when editing user files.
- Back up and validate before changing SSH configuration.
- Use `--` before paths that may begin with `-`.
- Run `shellcheck` on changed files.

### JavaScript

- ES modules, no build step in the bundled app.
- Node 18+ APIs; avoid experimental flags.
- No new runtime dependency without justification and a license check.
- Use `node --check` for syntax validation.

### YAML

- Add-on `config.yaml` must remain valid Home Assistant add-on schema.
- Do not add a `ports:` mapping. The add-on is Ingress-only.
- Bump `version` when behavior changes.

### Documentation

- Write for an operator who has never seen the project.
- Use present tense and exact paths.
- Never use a real private IP, hostname, token, or customer name as an example. Use documentation ranges (`192.0.2.0/24`, `2001:db8::/32`, `server.example.com`).
- Verify relative links and copy-paste commands.
- Mark untested claims as untested.

## Commit messages

Use an imperative subject line, 72 characters or fewer:

```text
Fix tunnel key migration for unrelated keys
Add repository hygiene checks
Document v1.0.0 upgrade path
```

Include a body when the change is not obvious. Reference issues with `Fixes #123`.

## Pull requests

Include:

- what changed and why;
- user-visible impact;
- security impact, including new network listeners or file writes;
- tests run, with command output summary;
- platforms actually exercised (native, VM, container, emulated, unit);
- documentation updates;
- rollback plan for lifecycle changes.

Do not include generated secrets, local paths with your username, or screenshots of real dashboards. Redact before posting.

## Adding a test

- Place shell regressions in `tests/` with a `test_` prefix.
- Place Node tests in `tests/` (or `tests/unit/` for pure units).
- Each test must print `[PASS]`/`[FAIL]` lines and a summary, and exit non-zero on failure.
- Use `mktemp -d` and clean up with `trap`.
- Never depend on a developer's home directory or a pre-existing port. Allocate free ports.
- For network tests, bind loopback only and close listeners in `finally`.

## Security review checklist

- [ ] No secret is passed on a command line.
- [ ] No secret is printed, including in error paths.
- [ ] File permissions are restrictive and ownership is set.
- [ ] A failed validation leaves the previous configuration active.
- [ ] A failed update cannot leave a wildcard bind.
- [ ] No new WAN listener, firewall rule, or published container port.
- [ ] `authorized_keys` edits preserve unrelated lines.
- [ ] Host key verification remains fail-closed.
- [ ] New dependencies have acceptable licenses.

## Regenerating the icon

```bash
python3 assets/generate-icon.py
```

This requires Pillow. It writes `haos-addon/icon.png` (256×256) and `haos-addon/logo.png` (512×512). Commit both files and the generator change together.

## License

By contributing, you agree that your contribution is licensed under the MIT License and that you have the right to submit it.
