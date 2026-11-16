# Changelog

## 1.0.1 - Unreleased

### Fixed
- HAOS add-on startup: migrated to Home Assistant base image with s6-overlay service layout.
- Set `init: false` so s6 manages PID 1; removed direct `CMD` that triggered `s6-overlay-suexec: fatal: can only run as pid 1`.
- Updated build base image to `ghcr.io/home-assistant/{arch}-base:3.20`.

### Fixed (previous)
- (prior 1.0.1 fixes retained)

- Host key parsing is now strict and fails closed. Invalid key type, encoding, host, port, or empty input is rejected.
- SSH now sets `UpdateHostKeys=no` and `VerifyHostKeyDNS=no`.
- `remote_host` values outside loopback produce an explicit warning instead of a confusing forwarding failure.
- Removed legacy private deployment fallbacks (`tx3_*`) from option handling.

### Added

- `hostkey.mjs` with focused unit tests.
- Optional translations for all add-on options.
- `backup: cold` so `/data` is backed up safely.
- Diagnostic down page listing target, configuration state, and the add-on public key.

### Security

- No host ports are published; access is Ingress-only.
- Tunnel key is restricted to `127.0.0.1:8320` and remote forwarding is disabled server-side.

## 1.0.0 - 2026-11-11

### Added

- Initial Ingress tunnel add-on.
- Ed25519 key generation under `/data`.
- Ingress path, cookie, and redirect rewriting.
- Health endpoint and watchdog.
