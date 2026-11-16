# Changelog

All notable changes to this project are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.3] - Unreleased

### Fixed

- **SSH tunnel could not work in v1.0.0.** The generated `authorized_keys` line contained `no-port-forwarding`, which disables `permitopen` and rejects every local forward. The option has been removed; `permitopen="127.0.0.1:8320"` now works.
- **Legitimate keys were overwritten.** Installing a tunnel key now appends to `authorized_keys` and preserves unrelated administrator and third-party keys.
- **Existing installations were never migrated.** `install.sh` and `update.sh` now rewrite v1.0.0 tunnel keys in place, with a timestamped backup and an idempotent second run.
- **Wildcard bind could survive an upgrade.** `manager.env` is rewritten to `HOST=127.0.0.1` during install, update, and restore.
- **Remote forwarding was not fully blocked.** A per-user `Match` block now sets `AllowTcpForwarding local`, `AllowStreamLocalForwarding no`, `PermitListen none`, and `PermitOpen 127.0.0.1:8320`. Key options alone were insufficient.
- **Unhealthy updates reported success.** `update.sh` now exits non-zero, restores the pre-update application tree, restarts the service, and re-checks health.
- **Failed updates changed SSH access.** Key and sshd migrations now run only after the new version is healthy.
- **`sync_secret.js` was called without arguments**, so `CLIPROXYAPI_MANAGEMENT_KEY` could not be synchronized. Correct config and env paths are now passed.
- **HAOS host key pinning was permissive.** A dedicated `hostkey.mjs` validates key type, encoding, host, and port; invalid input fails closed.
- **The add-on could downgrade host keys.** `UpdateHostKeys=no` and `VerifyHostKeyDNS=no` are now set.
- **The add-on still contained private deployment fallback options.** They were removed.

### Added

- `server-installer/lib/sshd_policy.sh` for safe, validated, reload-only per-user SSH policy management.
- `repository.yaml`, add-on translations, and original 256×256 / 512×512 icon assets.
- `docs/` covering installation, operations, architecture, upgrading, troubleshooting, the add-on, and the release process.
- Public contribution, security, code-of-conduct, issue, and pull-request material.
- Regression suites for key migration, sshd policy, update rollback, v1.0.0→v1.0.1 migration, host-key parsing, and real-service loopback binding.
- Real OpenSSH end-to-end forwarding tests (20 checks) and real Account Manager socket tests (16 checks).
- Repository hygiene tests covering icon dimensions, add-on metadata, version consistency, documentation links, and private-data markers.

### Changed

- Embedded Account Manager bundle is runtime-only (`src/`, `public/`, package metadata, LICENSE), versioned `1.0.1`, with a new SHA-256 checksum.
- Diagnostics now detect wildcard binds, legacy `no-port-forwarding` keys, and a missing sshd policy, with remediation hints.
- Backup includes the tunnel `authorized_keys` and managed sshd policy for disaster-recovery reference.
- `uninstall.sh --purge-data` removes the managed tunnel key and sshd policy; default uninstall preserves SSH access and all data.
- systemd unit hardening was extended and the unit description no longer says "LAN".

### Security

- Account Manager remains loopback-only by invariant.
- CLIProxyAPI management stays loopback-only with `management.allow-remote: false`.
- No firewall changes and no WAN ports are introduced.

### Migration notes

- v1.0.0 installations are migrated automatically by `cliproxy-manager update` or by re-running `install.sh`.
- The migration is idempotent and preserves unrelated keys byte-for-byte.
- See [docs/UPGRADING.md](docs/UPGRADING.md).

## [1.0.0] - 2026-11-11

### Added

- Automated installer for Debian 12/13 and Ubuntu LTS on AMD64 and ARM64.
- Unified `cliproxy-manager` CLI: `install`, `check`, `check-update`, `update`, `backup`, `restore`, `diagnostics`, `uninstall`.
- Home Assistant OS tunnel add-on with dynamic Ingress HTML/JS rewriting.
- Restricted SSH tunnel provisioning with `permitopen` and `command="/bin/false"`.
- Snapshot, rollback, and checksum-verified backup/restore workflows.
- Unit and integration test suites and a GitHub Actions workflow.

### Known issues

- `no-port-forwarding` in the generated key disables the tunnel (fixed in 1.0.1).
- Remote forwarding was only partially restricted (fixed in 1.0.1).
- `update.sh` did not fail on an unhealthy service (fixed in 1.0.1).

[1.0.1]: https://github.com/quangtienhn/cliproxyapi-manager/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/quangtienhn/cliproxyapi-manager/releases/tag/v1.0.0
