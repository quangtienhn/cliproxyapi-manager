# Installation Guide

This guide takes you from a fresh Debian or Ubuntu server to a working Account Manager, then connects it to Home Assistant OS through the Ingress add-on.

If you only want to upgrade an existing v1.0.0 installation, read [UPGRADING.md](UPGRADING.md).

## 1. Before you begin

### Supported server platforms

| Platform | Architecture | Support level |
| --- | --- | --- |
| Debian 12 (Bookworm) | AMD64 | Target |
| Debian 12 (Bookworm) | ARM64 | Target |
| Debian 13 (Trixie) | AMD64 | Target |
| Debian 13 (Trixie) | ARM64 | Target |
| Ubuntu 22.04 LTS | AMD64 | Target |
| Ubuntu 24.04 LTS | AMD64 | Target |
| Ubuntu 24.04 LTS | ARM64 | Target |

"Target" means the code is written for that platform and is exercised in simulation. Native bare-metal and VM installs were **not** performed during the v1.0.1 public-readiness audit. Treat the first install on a new platform as a change that needs a maintenance window and a backup.

Other Linux distributions may work but are unsupported.

### Requirements

- Root or `sudo`.
- systemd.
- OpenSSH server (`openssh-server`), reachable from Home Assistant.
- Node.js **18 or newer** and `npm` (used only for the bundled `yaml` dependency).
- `curl`, `tar`, `sha256sum`, `ss` (iproute2).
- CLIProxyAPI installed and running separately, with:
  - config at `/etc/cliproxyapi/config.yaml`;
  - management API on `127.0.0.1:8317`;
  - `management.allow-remote: false`;
  - OAuth directory at `/var/lib/cliproxyapi/auths` (default).

The installer does not install or upgrade CLIProxyAPI.

### Install Node.js 18+ on Debian/Ubuntu

Check first:

```bash
node --version
```

If it prints `v18` or newer, skip this section. Otherwise, on Debian 12/13 the distribution package is usually sufficient:

```bash
sudo apt-get update
sudo apt-get install -y nodejs npm
```

On Ubuntu 22.04, use the NodeSource 20.x repository:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

NodeSource is a third-party repository. Review their script before running it if your policy requires that. Either way, confirm:

```bash
node --version   # must be v18 or newer
```

### Confirm CLIProxyAPI is healthy

```bash
sudo systemctl status cliproxyapi --no-pager
sudo ss -ltnp | grep ':8317'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8317/
```

The management API must be on `127.0.0.1`, not `0.0.0.0`.

## 2. Install the Account Manager on the server

```bash
git clone https://github.com/quangtienhn/cliproxyapi-account-manager-easy-installer.git
cd cliproxyapi-account-manager-easy-installer/server-installer
sudo bash install.sh --setup-tunnel-user
```

Useful options:

| Option | Meaning |
| --- | --- |
| `--non-interactive` | Do not prompt (the current installer has no prompts; kept for compatibility) |
| `--dry-run` | Validate OS, architecture, Node, and bundle checksum without changing the system |
| `--setup-tunnel-user` | Create or update the dedicated `amtunnel` account and SSH policy |
| `--tunnel-pubkey "ssh-ed25519 AAAA..."` | Authorize an existing tunnel public key |
| `--help` | Show usage |

The installer is idempotent. Re-running it upgrades the application tree, preserves `/etc/cliproxyapi-account-manager/manager.env` and OAuth data, and refreshes the SSH policy.

### What the installer writes

| Path | Purpose | Mode / owner |
| --- | --- | --- |
| `/opt/cliproxyapi-account-manager` | Web application | root:root, 0755 dirs / 0644 files |
| `/etc/cliproxyapi-account-manager/manager.env` | Runtime configuration | 0640, root:cliproxyapi |
| `/var/log/cliproxyapi-account-manager` | Application logs | 0750, cliproxyapi |
| `/var/lib/cliproxyapi-account-manager` | Admin state and session data | 0700, cliproxyapi |
| `/var/backups/cliproxyapi-account-manager` | Backups and snapshots | 0700, root |
| `/etc/systemd/system/cliproxyapi-account-manager.service` | systemd unit | 0644, root |
| `/usr/local/bin/cliproxy-manager` | CLI symlink into the clone | root |
| `/home/amtunnel/.ssh/authorized_keys` | Restricted tunnel key | 0600, amtunnel |
| `/etc/ssh/sshd_config` | Appended managed `Match User amtunnel` block | 0644, root |

Every edit to `authorized_keys` or `sshd_config` leaves a timestamped backup next to the original.

### Verify the installation

```bash
sudo cliproxy-manager check
```

Expected highlights:

```text
[OK] Account Manager is loopback-only.
[OK] Local Health Endpoint: {"status":"healthy",...}
[OK] Match User amtunnel policy is present in /etc/ssh/sshd_config.
```

Independent checks:

```bash
sudo ss -ltnp | grep ':8320'          # must show 127.0.0.1:8320, not 0.0.0.0
curl -s http://127.0.0.1:8320/api/health
sudo systemctl status cliproxyapi-account-manager --no-pager
```

### First administrator login

Two supported paths:

**A. Temporary SSH tunnel from your workstation**

```bash
ssh -N -L 8320:127.0.0.1:8320 your-admin-user@server.example.com
```

Keep that session open and browse to <http://127.0.0.1:8320>. Create the administrator password on first visit. Close the SSH session when done.

**B. Home Assistant Ingress**

Configure the add-on as described below, then open the Account Manager panel from the Home Assistant sidebar.

The first visit shows a setup form. Password minimum length is 8 characters. The password hash is stored in `/var/lib/cliproxyapi-account-manager/admin.json` with mode `0600`.

## 3. Install the Home Assistant OS add-on

### Add the repository

1. Home Assistant → **Settings → Add-ons → Add-on Store**.
2. Top-right **⋮ → Repositories**.
3. Add:

   ```text
   https://github.com/quangtienhn/cliproxyapi-account-manager-easy-installer
   ```

4. Close the dialog and refresh the store.

The repository root contains `repository.yaml`; the add-on lives in `haos-addon/`.

### Install the add-on

1. Find **CLIProxyAPI Account Manager Tunnel**.
2. Open it and select **Install**.
3. Wait for the Supervisor build to finish.

### Get the server host key

On the server:

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
```

Compare the fingerprint with what the server reports on its console or through another trusted channel. Copy the entire public key line, beginning with `ssh-ed25519`.

### Configure the add-on

Open the add-on **Configuration** tab:

| Option | Value |
| --- | --- |
| `server_host` | DNS name or IP of the Debian/Ubuntu server |
| `server_port` | SSH port, usually `22` |
| `server_user` | `amtunnel` |
| `remote_host` | `127.0.0.1` (leave as-is) |
| `remote_port` | `8320` (leave as-is) |
| `host_key` | The complete server host public key line |

Save and start the add-on.

### Authorize the add-on key on the server

On first start the add-on generates an Ed25519 key pair under `/data` and logs only the **public** key and fingerprint:

```text
[tunnel] SSH_PUBLIC_KEY=ssh-ed25519 AAAA... amtunnel@haos
[tunnel] SSH_FINGERPRINT=SHA256:...
```

Copy the full `SSH_PUBLIC_KEY` value, then on the server:

```bash
cd cliproxyapi-account-manager-easy-installer/server-installer
sudo bash install.sh --setup-tunnel-user \
  --tunnel-pubkey "ssh-ed25519 AAAA... amtunnel@haos"
```

The command appends the key without touching your existing administrator keys and installs the per-user sshd policy. The add-on retries every 15 seconds and connects automatically.

### Open the panel

Return to the add-on and select **Open Web UI**, or use the **Account Manager** entry in the Home Assistant sidebar. The add-on proxies the Account Manager through Ingress; it does not publish a host port.

## 4. Post-install checklist

- [ ] `sudo cliproxy-manager check` reports loopback-only and healthy.
- [ ] `sudo ss -ltnp | grep ':8320'` shows only `127.0.0.1:8320`.
- [ ] `management.allow-remote` is `false` in `/etc/cliproxyapi/config.yaml`.
- [ ] No firewall rule or router port-forward exposes `8320`.
- [ ] The administrator password is stored in a password manager.
- [ ] A first backup exists: `sudo cliproxy-manager backup`.
- [ ] The HAOS add-on shows a connected tunnel and the panel loads.
- [ ] You have recorded the server host key fingerprint somewhere trusted.

## 5. Uninstall

Preserve data and SSH access:

```bash
sudo cliproxy-manager uninstall
```

This removes the application, service unit, and CLI symlink, but keeps configuration, OAuth credentials, logs, backups, the tunnel account, and the sshd policy.

Remove App Manager data and tunnel access as well:

```bash
sudo cliproxy-manager uninstall --purge-data --force
```

This also removes `/etc/cliproxyapi-account-manager`, `/var/lib/cliproxyapi-account-manager`, the log directory, the managed tunnel key, and the managed sshd policy. Backups are still preserved. The `amtunnel` account remains but has no authorized key; remove it manually if you no longer need it:

```bash
sudo userdel -r amtunnel
```

Removing the account is outside the uninstaller because it may be shared with a future reinstall.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md). The most common causes are:

- host key pasted with a leading `ssh-ed25519` twice, or a mismatched key;
- the tunnel public key was never authorized on the server;
- CLIProxyAPI is not running, so the Account Manager UI loads but account operations fail;
- a v1.0.0 key with `no-port-forwarding` was restored from an old backup - run `sudo cliproxy-manager update` to migrate it.
