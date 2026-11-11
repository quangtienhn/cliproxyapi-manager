# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-11-11

### Added
- Complete automated server installer for Debian 12/13 (AMD64 and ARM64) and Ubuntu LTS.
- Unified `cliproxy-manager` CLI with subcommands: `install`, `check`, `check-update`, `update`, `backup`, `restore`, `diagnostics`, `uninstall`.
- Home Assistant OS Tunnel Add-on with dynamic Ingress HTML/JS reverse-proxy rewriter.
- Restricted SSH tunnel provisioning with strict `permitopen` and `command="/bin/false"`.
- Secure snapshot creation, rollback routines, and checksum-verified backup/restore workflows.
- Comprehensive automated test suite (unit and integration simulations).
- GitHub Actions CI validation workflow.
