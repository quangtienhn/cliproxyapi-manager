# CLIProxyAPI Manager

A hardened installer and lifecycle manager for the **CLIProxyAPI Manager** web UI, with an optional **Home Assistant OS Ingress add-on** for secure remote access.

The Account Manager is a small web application that sits next to [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and lets you review accounts, start OAuth flows, and manage provider credentials. This repository installs it on Debian/Ubuntu, keeps it bound to loopback, and exposes it to Home Assistant through a restricted SSH tunnel - never through a public port.

> **Project status: v1.0.1 release candidate.** See [Validation status](#validation-status) for exactly what has and has not been tested. This repository does not include CLIProxyAPI itself.

## What you get

- **Server installer** for Debian 12/13 and Ubuntu LTS on AMD64 and ARM64.
- **Unified management CLI** (`cliproxy-manager`) for health checks, updates, backup, restore, diagnostics, and uninstall.
- **Loopback-only Account Manager** (`127.0.0.1:8320`) with a hardened systemd unit.
- **Dedicated SSH tunnel account** (`amtunnel`) restricted to one destination and nothing else.
- **Home Assistant OS add-on** with Ingress panel, pinned SSH host keys, and no published host ports.
- **Safe upgrades** with checksum verification, pre-update snapshots, and automatic rollback.
- **Secret-aware operations**: no secrets in arguments, logs, backups metadata, or diagnostic output.

## Architecture

```text
 Home Assistant OS                          Debian / Ubuntu server
 ┌────────────────────────┐                 ┌─────────────────────────────────────┐
 │ Account Manager panel  │  HA Ingress     │  sshd (port 22)                      │
 │ (add-on, port 8080)    │◄───────────────►│    └─ Match User amtunnel            │
 │                        │                 │         AllowTcpForwarding local     │
 │ local reverse proxy    │  SSH tunnel     │         PermitOpen 127.0.0.1:8320    │
 │ 127.0.0.1:18320        │◄───────────────►│         PermitListen none            │
 └────────────────────────┘                 │                                       │
                                            │  Account Manager 127.0.0.1:8320      │
                                            │        │                              │
                                            │  CLIProxyAPI 127.0.0.1:8317          │
                                            └─────────────────────────────────────┘
```

No inbound port is opened for the Account Manager. The HAOS add-on never publishes a host port; it is reachable only through the Home Assistant Ingress proxy.

## Quick start

### 1. Server

Prerequisites: a supported Debian/Ubuntu host, root or sudo, systemd, OpenSSH server, and Node.js 18 or newer. CLIProxyAPI should already be installed and running; see [docs/INSTALLATION.md](docs/INSTALLATION.md) for the full prerequisite list.

```bash
git clone https://github.com/quangtienhn/cliproxyapi-manager.git
cd cliproxyapi-manager/server-installer
sudo bash install.sh --setup-tunnel-user
```

The installer:

1. verifies the embedded application bundle checksum;
2. installs the web UI to `/opt/cliproxyapi-account-manager`;
3. writes `/etc/cliproxyapi-account-manager/manager.env` with `HOST=127.0.0.1`;
4. creates the `amtunnel` account and a per-user `sshd` policy;
5. installs and starts the systemd service.

Verify locally on the server:

```bash
sudo cliproxy-manager check
curl -s http://127.0.0.1:8320/api/health
```

### 2. Home Assistant OS add-on

1. In Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**.
2. Add `https://github.com/quangtienhn/cliproxyapi-manager`.
3. Install **CLIProxyAPI Manager Tunnel**.
4. Configure `server_host`, `server_port`, `server_user` (`amtunnel`), and paste the server's SSH host public key into `host_key`.
5. Start the add-on and copy the generated tunnel public key from its log.
6. On the server, authorize that key:

```bash
cd cliproxyapi-manager/server-installer
sudo bash install.sh --setup-tunnel-user --tunnel-pubkey "ssh-ed25519 AAAA... amtunnel@haos"
```

The add-on reconnects automatically. Open **Account Manager** from the Home Assistant sidebar. The first visit asks you to create the administrator password.

Full walkthrough, key rotation, and troubleshooting: [docs/INSTALLATION.md](docs/INSTALLATION.md) and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Management commands

| Command | Purpose |
| --- | --- |
| `sudo cliproxy-manager check` | Health, listener, and configuration checks |
| `sudo cliproxy-manager check-update` | Show installed version and update readiness |
| `sudo cliproxy-manager update` | Update with snapshot and automatic rollback |
| `sudo cliproxy-manager backup` | Back up config, CLIProxyAPI config, and OAuth credentials |
| `sudo cliproxy-manager restore [DIR]` | Restore a verified backup (latest by default) |
| `sudo cliproxy-manager diagnostics` | Print a redacted diagnostic report |
| `sudo cliproxy-manager uninstall` | Remove the app, preserve data and SSH access |
| `sudo cliproxy-manager uninstall --purge-data` | Also remove Account Manager data, tunnel key, and sshd policy |

`cliproxy-manager` is a symlink to `server-installer/bin/cliproxy-manager` in the cloned repository. If you move or delete the clone, run the scripts directly from `server-installer/` or recreate the symlink.

## Security model (summary)

- Account Manager binds **`127.0.0.1:8320` only**; the template cannot request a wildcard bind, and install/update/restore rewrite legacy `HOST=0.0.0.0`.
- CLIProxyAPI Management API stays on `127.0.0.1:8317` with `management.allow-remote: false`.
- The tunnel key is restricted with `command="/bin/false"`, `no-pty`, `no-agent-forwarding`, `no-X11-forwarding`, `no-user-rc`, `permitopen="127.0.0.1:8320"`, and `permitlisten="127.0.0.1:1"`.
- A per-user `sshd` block additionally enforces `AllowTcpForwarding local`, `AllowStreamLocalForwarding no`, `PermitOpen 127.0.0.1:8320`, and `PermitListen none`, so remote forwarding cannot be used even if the key options are edited.
- The HAOS add-on pins the server host key and rejects empty, malformed, or mismatched pins.
- The installer never edits firewall rules and never opens a WAN port.

Read [SECURITY.md](SECURITY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before exposing the service to a network you do not control.

## Validation status

| Area | Status | Evidence |
| --- | --- | --- |
| Shell library, migration, and sshd policy regressions | **Passed on test host** | `tests/test_migration_logic.sh`, `tests/test_sshd_policy.sh`, `tests/test_update_rollback.sh`, `tests/test_upgrade_migration.sh` |
| Real OpenSSH forwarding restrictions | **Passed on test host** | `tests/test_ssh_hardening.sh` (portable OpenSSH, 20 checks) |
| Real Account Manager loopback binding | **Passed on test host** | `tests/test_real_service_loopback.js` (actual embedded app, socket inspection, LAN reachability) |
| HAOS host-key parser | **Passed on test host** | `tests/test_hostkey_parser.js` |
| Debian/Ubuntu bare metal and VM installation | **Not verified in this environment** | Cross-platform simulations only; see [reports/PUBLIC-RELEASE-READINESS.md](reports/PUBLIC-RELEASE-READINESS.md) |
| ARM64 native installation | **Not verified** | No ARM64 hardware available during this audit |
| Real Home Assistant OS add-on install and Ingress | **Not verified** | Add-on structure validated; Supervisor build not run |
| CLIProxyAPI Management API integration | **Not verified** | External component, not included in this repository |

The project distinguishes native execution, VM/container execution, emulation, and unit-level simulation. It does not claim a platform works merely because a simulation passed.

## Documentation

- [Installation](docs/INSTALLATION.md)
- [Operations, backup, and restore](docs/OPERATIONS.md)
- [Architecture and security invariants](docs/ARCHITECTURE.md)
- [Upgrading from v1.0.0](docs/UPGRADING.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Home Assistant add-on guide](docs/HAOS-ADDON.md)
- [Release process](docs/RELEASE-PROCESS.md)
- [Contributing](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md)
- [Third-party notices](THIRD-PARTY-NOTICES.md)
- [Security policy](SECURITY.md)
- [Public release readiness](reports/PUBLIC-RELEASE-READINESS.md)
- [Publication security audit](reports/PUBLICATION-SECURITY-AUDIT.md)
- [Real-service loopback verification](reports/REAL-SERVICE-LOOPBACK-VERIFICATION.md)

## License

MIT. See [LICENSE](LICENSE). Third-party components retain their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
