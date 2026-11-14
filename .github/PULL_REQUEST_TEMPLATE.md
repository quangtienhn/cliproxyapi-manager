# Pull request

## Summary

<!-- What changes, and why? -->

## Component

- [ ] Server installer / lifecycle scripts
- [ ] Embedded Account Manager bundle
- [ ] Home Assistant add-on
- [ ] Documentation
- [ ] Tests / CI
- [ ] Repository metadata or assets

## Security impact

<!-- New listeners, file writes, permissions, SSH policy changes, secret handling, dependency changes. Write "none" if truly none. -->

## Validation

<!-- List exact commands. Do not claim a platform you did not run. -->

| Check | Command | Result |
| --- | --- | --- |
| Shell tests | `bash tests/run_all.sh` | |
| SSH E2E | `bash tests/test_ssh_hardening.sh` | |
| Node syntax | `node --check ...` | |
| ShellCheck | `shellcheck -S error ...` | |
| Repository hygiene | `node tests/test_repo_hygiene.js` | |

Platforms actually exercised:

- [ ] Windows/Git Bash (unit only)
- [ ] Linux AMD64 (native or VM)
- [ ] Linux ARM64 (native or VM)
- [ ] Container
- [ ] Emulation/simulation only
- [ ] Home Assistant OS (real Supervisor)

## Checklist

- [ ] No secrets, private keys, tokens, private IPs, or hostnames added.
- [ ] Existing OAuth credentials and user configuration remain intact.
- [ ] No new WAN listener, firewall change, or published container port.
- [ ] `HOST=127.0.0.1` remains the default and is enforced on migration.
- [ ] SSH changes are validated with `sshd -t` and have a rollback path.
- [ ] Failed operations leave the previous configuration active.
- [ ] Documentation is updated and relative links resolve.
- [ ] Tests were added or updated for behavior changes.
- [ ] Version numbers and changelogs are consistent.
- [ ] I did not modify or force-push a published release tag.

## Rollback plan

<!-- How can this change be reverted safely? -->
