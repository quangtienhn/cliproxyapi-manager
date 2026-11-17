# Architecture and Security Invariants

## 1. Components

```text
┌─────────────────────────── Home Assistant OS ────────────────────────────┐
│                                                                          │
│  Browser ──► HA frontend ──► Ingress (auth, TLS) ──► Add-on:8080          │
│                                                       proxy.mjs           │
│                                                         │                 │
│                                                         ▼                 │
│                                              127.0.0.1:18320             │
│                                              (SSH local forward)          │
└─────────────────────────────────────────────────────────┬────────────────┘
                                                          │ SSH (port 22)
                                                          ▼
┌──────────────────────── Debian / Ubuntu server ──────────────────────────┐
│  sshd                                                                    │
│   └─ Match User amtunnel                                                 │
│        AllowTcpForwarding local                                          │
│        PermitOpen 127.0.0.1:8320                                         │
│        PermitListen none                                                 │
│                                                                          │
│  Account Manager  node src/server.js  127.0.0.1:8320                     │
│   ├─ static UI (public/)                                                 │
│   ├─ session + admin state (/var/lib/cliproxyapi-account-manager)        │
│   ├─ audit log (/var/log/cliproxyapi-account-manager/audit.log)          │
│   └─ HTTP client ──► CLIProxyAPI management 127.0.0.1:8317               │
│                       └─ provider OAuth data /var/lib/cliproxyapi/auths  │
└──────────────────────────────────────────────────────────────────────────┘
```

### Server installer (`server-installer/`)

Bash scripts that provision the application and system integration:

| File | Responsibility |
| --- | --- |
| `install.sh` | Prerequisite checks, bundle checksum, directory layout, config, key migration, sshd policy, systemd |
| `update.sh` | Checksum verification, snapshot, atomic swap, health gate, post-success migrations, rollback |
| `backup.sh` | Copies config, CLIProxyAPI config, OAuth files, tunnel material, unit, and checksums |
| `restore.sh` | Verifies checksums, snapshots current state, restores config and OAuth, re-enforces loopback |
| `diagnostics.sh` | Read-only health, listener, permission, and restriction report |
| `uninstall.sh` | Removes the application; optional purge of data and tunnel access |
| `lib/installer_core.sh` | Key generation/validation, `authorized_keys` append and migration, loopback enforcement |
| `lib/sshd_policy.sh` | Managed `Match` block install/remove, validation, rollback, reload |
| `bin/cliproxy-manager` | Command dispatcher |
| `embedded/` | Immutable application bundle, `yaml` dependency, checksums |

### Account Manager (`embedded/cliproxyapi-account-manager-v1.0.3.tar.gz`)

A Node.js application (ES modules) with no build step. Runtime files:

- `src/server.js` - HTTP server and API routes, including account deletion and Pause/Resume endpoints;
- `src/auth.js`, `src/auth_store.js` - password hashing, sessions, CSRF, safe auth-file operations and persisted account state;
- `src/account_status.js` - CLIProxyAPI Management API client for native credential disable/enable;
- `src/audit.js` - JSON-lines audit log;
- `src/providers/` - provider-specific OAuth flows;
- `src/sync_secret.js` - copies `management.secret-key` from CLIProxyAPI YAML into `manager.env`;
- `public/` - static UI.

The bundle contains no `deploy/`, `docs/`, `tests/`, or repository documentation. It is versioned `1.0.3` and verified by `embedded/SHA256SUMS-v1.0.3.txt`.

The editable source that produces this bundle is kept in `account-manager/` at the repository root, including its `src/`, `public/`, `tests/`, and version metadata. `account-manager/NOTICE.md` preserves the original application author attribution.

### HAOS add-on (`haos-addon/`)

| File | Responsibility |
| --- | --- |
| `config.yaml` | Add-on metadata, Ingress, options, schema |
| `Dockerfile` | Alpine + OpenSSH client + Node.js |
| `rootfs/run.sh` | Generates the tunnel key, pins the host key, supervises `ssh -N -L`, restarts on failure |
| `rootfs/hostkey.mjs` | Strict host-key parser and `known_hosts` writer |
| `rootfs/proxy.mjs` | Ingress-aware reverse proxy and health endpoint |

The add-on has no `ports:` mapping. Its only exposure is the Supervisor Ingress proxy, which authenticates the Home Assistant user before forwarding.

## 2. Trust boundaries

| Boundary | Trusted side | Untrusted side | Control |
| --- | --- | --- | --- |
| Browser → Home Assistant | HA frontend | Internet/LAN | HA authentication, TLS |
| HA → add-on | Supervisor | Add-on container | Ingress token, container network |
| Add-on → server | `amtunnel` key holder | Network | SSH host key pinning, public-key auth |
| SSH session | Server `sshd` | Tunnel client | Per-user `Match` policy + key options |
| Account Manager → CLIProxyAPI | Local process | Loopback HTTP | Management secret, `allow-remote: false` |
| Installer → OS | Root | Repository content | Bundle SHA-256, `node --check`, `sshd -t` |

The tunnel key holder is treated as **partially trusted**: they may reach the Account Manager, but must not obtain a shell, run commands, allocate a PTY, forward to another service, or create a server-side listener.

## 3. Request flow

1. The Home Assistant user opens the panel.
2. HA Ingress authenticates the user and forwards the request to the add-on on port 8080, adding `X-Ingress-Path`.
3. `proxy.mjs` strips the ingress prefix, forwards the request to `127.0.0.1:18320`, and rewrites absolute paths, cookies, and redirects in text responses so the UI works under the prefix.
4. The SSH client forwards `127.0.0.1:18320` to `127.0.0.1:8320` on the server.
5. `sshd` accepts the channel only because `PermitOpen 127.0.0.1:8320` matches and `AllowTcpForwarding local` is active.
6. `src/server.js` authenticates the session cookie and calls CLIProxyAPI on `127.0.0.1:8317` with the management secret.
7. CLIProxyAPI reads or writes provider credentials under `/var/lib/cliproxyapi/auths`.

No step uses a public listener on the server.

## 4. Invariants

These are non-negotiable; tests assert them.

1. **Loopback bind**
   - `manager.env.template` contains `HOST=127.0.0.1`.
   - `install.sh`, `update.sh`, and `restore.sh` call `enforce_loopback_bind`.
   - `diagnostics.sh` warns on `0.0.0.0`, `*`, or `[::]`.
2. **Single permitted forward**
   - `permitopen="127.0.0.1:8320"` in the key.
   - `PermitOpen 127.0.0.1:8320` in the `Match` block.
3. **No server-side listener**
   - `PermitListen none` and `AllowTcpForwarding local`.
   - `permitlisten="127.0.0.1:1"` as a secondary boundary.
4. **No code execution**
   - `command="/bin/false"`, `ForceCommand /bin/false`, account shell `/bin/false`.
   - `PermitTTY no`, agent and X11 forwarding disabled.
5. **No Unix-socket pivot**
   - `AllowStreamLocalForwarding no`.
6. **Host key pinning**
   - `StrictHostKeyChecking=yes`, isolated `known_hosts`, no host-key updates.
7. **Secret confinement**
   - No secrets in process arguments.
   - Config `0640`, credentials `0600`, backup roots `0700`.
   - Diagnostics redact known secret patterns.
8. **Lifecycle safety**
   - Bundle checksum verified before extraction.
   - Failed update restores the previous application tree.
   - SSH migration runs only after a healthy update.
   - Restore verifies every file before writing.
   - Uninstall preserves data by default.
9. **No firewall mutation**
   - No `iptables`, `nft`, `ufw`, or router changes.

## 5. Filesystem and ownership

| Path | Owner | Mode |
| --- | --- | --- |
| `/opt/cliproxyapi-account-manager` | root:root | 0755/0644 |
| `/etc/cliproxyapi-account-manager` | root:cliproxyapi | 0750 |
| `/etc/cliproxyapi-account-manager/manager.env` | root:cliproxyapi | 0640 |
| `/var/log/cliproxyapi-account-manager` | cliproxyapi | 0750 |
| `/var/lib/cliproxyapi-account-manager` | cliproxyapi | 0700 |
| `/var/backups/cliproxyapi-account-manager` | root | 0700 |
| `/home/amtunnel/.ssh` | amtunnel | 0700 |
| `/home/amtunnel/.ssh/authorized_keys` | amtunnel | 0600 |
| `/etc/ssh/sshd_config` | root:root | 0644 |

## 6. Failure modes and responses

| Failure | Detection | Response |
| --- | --- | --- |
| Bundle corrupted in transit | SHA-256 mismatch | Installer aborts before extraction |
| New version crashes | `/api/health` never returns healthy | Restore snapshot, restart, re-check, exit 1 |
| `sshd_config` invalid | `sshd -t` fails | Generated file discarded; live config untouched |
| SSH reload fails | `systemctl reload` non-zero | Restore backup, re-validate, reload again |
| Host key changed | Pinned `known_hosts` mismatch | SSH refuses; add-on page shows target and status |
| Tunnel key not authorized | SSH permission denied | Add-on retries every 5s; page shows the public key |
| Wildcard bind restored from backup | `HOST=0.0.0.0` found | Rewrite to `127.0.0.1` before restart |
| Backup tampered | `sha256sum -c` fails | Restore aborts before writing |
| Old `no-port-forwarding` key | Migration detects it | Rewrite with backup; idempotent |

## 7. What this project does not cover

- Installing, configuring, or updating CLIProxyAPI.
- Issuing TLS certificates or reverse-proxying the Account Manager directly.
- Host firewall management, router configuration, or VPN setup.
- Multi-user Account Manager roles; it has a single administrator.
- Encryption of backups at rest.
- High availability or multi-server deployment.
- Real HAOS Supervisor behavior beyond structural validation in this audit.

See [../reports/PUBLIC-RELEASE-READINESS.md](../reports/PUBLIC-RELEASE-READINESS.md) for the evidence status of each limitation.
