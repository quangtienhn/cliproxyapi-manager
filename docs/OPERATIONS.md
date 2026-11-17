# Operations Guide

Day-to-day operation, backup, restore, key rotation, and recovery for the CLIProxyAPI Manager.

All commands require root or `sudo`. `cliproxy-manager` is a symlink to `server-installer/bin/cliproxy-manager` inside the clone; if the clone moves, run the scripts directly.

## 1. Daily checks

```bash
sudo cliproxy-manager check
```

This prints:

- OS, architecture, Node, and kernel;
- systemd state for the Account Manager and CLIProxyAPI;
- listening sockets for `8320` and `8317`, with a warning if either is on a wildcard address;
- the local health endpoint response;
- a redacted view of `manager.env`;
- tunnel `authorized_keys` restrictions and the managed sshd policy status.

A healthy installation shows:

```text
[OK] Account Manager is loopback-only.
[OK] Account Manager process responds.
[OK] Match User amtunnel policy is present in /etc/ssh/sshd_config.
```

Useful independent commands:

```bash
sudo systemctl status cliproxyapi-account-manager --no-pager
sudo journalctl -u cliproxyapi-account-manager -n 100 --no-pager
sudo ss -ltnp | grep -E ':(8320|8317)'
curl -s http://127.0.0.1:8320/api/health
```

Never expose `8320` to fix a connectivity problem. Use an SSH local forward or the HAOS Ingress panel.

### Routine account operations

- **Delete an account:** click `Delete` on the exact row. This works for every provider, including Gemini/Antigravity files such as `antigravity-user@example.com.json`. A backup is created after the target is validated. See [PAUSE-RESUME.md](PAUSE-RESUME.md) for filename rules.
- **Pause an account:** click `Pause` on an Active row. CLIProxyAPI disables the credential natively; no token is removed and the account is not selected for new requests.
- **Resume an account:** click `Resume` on a Paused row. No re-login is needed while the credential is still valid. Errors are shown and leave the credential unchanged.
- Paused accounts do not count as Active. Full usage notes are in [PAUSE-RESUME.md](PAUSE-RESUME.md).

## 2. Updates

Check the installed version:

```bash
sudo cliproxy-manager check-update
```

Apply the update bundled with the checked-out repository:

```bash
cd cliproxyapi-manager
git pull --ff-only
cd server-installer
sudo bash update.sh
```

What `update.sh` does:

1. verifies the embedded bundle SHA-256;
2. snapshots the current application tree and systemd unit to
   `/var/backups/cliproxyapi-account-manager/snapshot_<timestamp>`;
3. validates the staged JavaScript with `node --check`;
4. atomically swaps the application directory;
5. rewrites a legacy `HOST=0.0.0.0` to `127.0.0.1`;
6. restarts the service and polls `/api/health` for up to five seconds;
7. on success, migrates v1.0.0 tunnel keys and refreshes the sshd policy;
8. on failure, restores the previous application tree, restarts, re-checks
   health, and exits non-zero.

A failed update does **not** change SSH access, because key and sshd migration run only after a healthy start. The loopback rewrite is intentionally not rolled back: the service must never return to a wildcard bind.

Use a custom bundle only if you built and verified it yourself:

```bash
sudo bash update.sh --tarball /path/to/verified-bundle.tar.gz
```

Custom bundles are not checksum-verified against the shipped `SHA256SUMS-v1.0.3.txt`.

### Recovering from a failed update

The updater prints the snapshot path. If the automatic rollback also fails:

```bash
ls -1 /var/backups/cliproxyapi-account-manager/
sudo systemctl status cliproxyapi-account-manager --no-pager
sudo journalctl -u cliproxyapi-account-manager -n 200 --no-pager
```

Restore the application tree from the snapshot:

```bash
sudo systemctl stop cliproxyapi-account-manager
sudo mv /opt/cliproxyapi-account-manager /opt/cliproxyapi-account-manager.broken
sudo cp -a /var/backups/cliproxyapi-account-manager/snapshot_<timestamp>/app \
  /opt/cliproxyapi-account-manager
sudo systemctl start cliproxyapi-account-manager
curl -s http://127.0.0.1:8320/api/health
```

Keep the broken tree until the cause is understood.

## 3. Backups

Create a backup:

```bash
sudo cliproxy-manager backup
```

The command prints the backup directory, for example:

```text
/var/backups/cliproxyapi-account-manager/backup_20261112T101500
```

Contents:

| Path | Contains |
| --- | --- |
| `config/` | `/etc/cliproxyapi-account-manager` (includes `manager.env`) |
| `cliproxyapi/config.yaml` | CLIProxyAPI configuration, including management settings |
| `auths/` | OAuth credential files from `/var/lib/cliproxyapi/auths` |
| `ssh/authorized_keys` | Tunnel key, for disaster-recovery reference |
| `ssh/sshd_policy.conf` | Managed sshd `Match` block, for reference |
| `cliproxyapi-account-manager.service` | systemd unit |
| `metadata.env` | Timestamp, version, OS, architecture |
| `SHA256SUMS.txt` | Checksums for every file except itself |

Permissions: backup root `0700`, files `0600`.

**Backups contain credentials and are not encrypted by this project.** Store them on encrypted media, restrict access, and do not attach them to issues. `auths/` and `config.yaml` are enough to impersonate provider accounts.

`latest_backup_path` points at the newest backup and is used by `restore` when no directory is given.

## 4. Restore

Restore the newest backup:

```bash
sudo cliproxy-manager restore
```

Restore a specific backup:

```bash
sudo cliproxy-manager restore /var/backups/cliproxyapi-account-manager/backup_20261112T101500
```

`restore.sh`:

1. verifies every file against the backup's `SHA256SUMS.txt` and aborts on mismatch;
2. copies the current configuration to
   `/var/backups/cliproxyapi-account-manager/pre_restore_safety_<timestamp>`;
3. restores `manager.env`, CLIProxyAPI config, and OAuth files with restrictive
   permissions;
4. rewrites a restored `HOST=0.0.0.0` to `127.0.0.1`;
5. restarts the Account Manager.

It does **not** restore the systemd unit, `authorized_keys`, or `sshd_config`. Restoring a service unit from an older release could undo hardening. If you need to rebuild the tunnel after a disk loss, re-run:

```bash
cd cliproxyapi-manager/server-installer
sudo bash install.sh --setup-tunnel-user --tunnel-pubkey "ssh-ed25519 AAAA... amtunnel@haos"
```

Restoring from a different host or after reinstalling CLIProxyAPI may leave credential files owned by the wrong account. Verify ownership:

```bash
sudo chown -R cliproxyapi:cliproxyapi /var/lib/cliproxyapi/auths
sudo chown root:cliproxyapi /etc/cliproxyapi-account-manager/manager.env
```

## 5. Rotating the tunnel key

1. Remove the add-on's data in Home Assistant (add-on → **Uninstall** removes the container but may keep `/data`; use the add-on's reset option or delete `/data/id_ed25519*` through the add-on container if you need a new key).
2. Start the add-on and copy the new public key from the log.
3. On the server:

   ```bash
   sudo bash install.sh --setup-tunnel-user --tunnel-pubkey "ssh-ed25519 NEWKEY amtunnel@haos"
   ```

4. Remove the old key. The installer does not delete keys it did not create. Edit the file carefully:

   ```bash
   sudo nano /home/amtunnel/.ssh/authorized_keys
   ```

   Delete only the old `permitopen="127.0.0.1:8320"` line for the retired key. A backup is created whenever the installer edits this file, but manual edits are not backed up automatically.

5. Confirm:

   ```bash
   sudo ssh-keygen -lf /home/amtunnel/.ssh/authorized_keys
   sudo cliproxy-manager check
   ```

If the old key is compromised, rotate immediately and review CLIProxyAPI audit logs and provider-side sessions.

## 6. Changing the Account Manager port

The supported port is `8320`. Changing it requires coordinated edits:

1. set `PORT` in `/etc/cliproxyapi-account-manager/manager.env`;
2. update the sshd policy and authorized key to the new port;
3. update the add-on `remote_port`;
4. restart both services.

There is no supported `--port` flag. Staying on `8320` is strongly recommended because tests and documentation assume it.

## 7. Logs and audit data

| Data | Location |
| --- | --- |
| systemd stdout/stderr | `journalctl -u cliproxyapi-account-manager` |
| Account Manager audit log | `/var/log/cliproxyapi-account-manager/audit.log` |
| CLIProxyAPI logs | `journalctl -u cliproxyapi` |
| Installer backups | `*.bak.*` next to the edited file |
| Update snapshots | `/var/backups/cliproxyapi-account-manager/snapshot_*` |

Audit entries include login success/failure, rate limiting, account operations, and OAuth session changes. They do not contain passwords or tokens.

Log rotation is not configured by this project. If the audit log grows, add a `logrotate` rule for `/var/log/cliproxyapi-account-manager/audit.log`.

## 8. Diagnostics for support

```bash
sudo cliproxy-manager diagnostics > /tmp/account-manager-diagnostics.txt
```

The report is redacted, but **review it before sharing**. Redaction is pattern-based and cannot guarantee that a novel secret format is removed. Delete anything that identifies your network if you are posting publicly.

Include in a bug report:

- version (`sudo cliproxy-manager check-update`);
- platform and architecture;
- the failing command and its exit code;
- sanitized diagnostics;
- relevant `journalctl` lines with hostnames and IPs removed.

## 9. Uninstall

Preserve data and SSH access (recommended):

```bash
sudo cliproxy-manager uninstall
```

Keeps configuration, OAuth credentials, logs, backups, the tunnel account, and the managed sshd policy. Re-running `install.sh` reuses them.

Full cleanup:

```bash
sudo cliproxy-manager uninstall --purge-data --force
```

Removes the application, Account Manager config/data/logs, the managed tunnel key, and the managed sshd policy. Backups and CLIProxyAPI data remain. Remove the account manually if it is no longer needed:

```bash
sudo userdel -r amtunnel
```

## 10. Periodic maintenance

Monthly:

- [ ] `sudo cliproxy-manager check`
- [ ] confirm no package update changed the Node major version unexpectedly
- [ ] verify `sudo ss -ltnp | grep -E ':(8320|8317)'` still shows loopback only
- [ ] run `sudo cliproxy-manager backup`
- [ ] copy the backup to encrypted off-host storage
- [ ] review `journalctl -u cliproxyapi-account-manager` for repeated login failures
- [ ] confirm the HAOS add-on is running and the panel loads

After a host reboot:

```bash
sudo cliproxy-manager check
```

After changing routers, VLANs, or firewalls, re-run the loopback checks. The installer never relies on a firewall for the loopback invariant.
