# Upgrading from v1.0.0 to v1.0.1

v1.0.0 has two defects that make the Home Assistant tunnel unusable and one that weakens remote-forwarding restrictions. v1.0.1 fixes them and migrates existing installations safely.

Read the whole page before starting. Take a backup first.

## 1. What changes

| Area | v1.0.0 | v1.0.1 |
| --- | --- | --- |
| Tunnel key | Contains `no-port-forwarding`, so every local forward is refused | `permitopen="127.0.0.1:8320"` works; no `no-port-forwarding` |
| Remote forwarding | Only `permitlisten="127.0.0.1:1"` | Per-user `Match` block: `AllowTcpForwarding local`, `PermitListen none` |
| `authorized_keys` handling | Overwrote the file | Appends, de-duplicates, preserves unrelated keys |
| Existing keys | Never migrated | Migrated idempotently with a timestamped backup |
| `HOST` | Template said `0.0.0.0` | `127.0.0.1`, enforced on install/update/restore |
| Failed health check | Warned and exited 0 | Restores the previous tree and exits 1 |
| Secret sync | Called without arguments | Passes CLIProxyAPI config and `manager.env` |
| HAOS host key | Permissive inline parser | Strict `hostkey.mjs`, fails closed |
| HAOS private fallbacks | Private deployment options | Removed |

## 2. Before you start

```bash
sudo cliproxy-manager check
sudo cliproxy-manager backup
sudo tar -C /var/backups/cliproxyapi-account-manager -czf /root/am-pre-upgrade-$(date +%F).tar.gz .
```

Store that archive off-host. It contains credentials; protect it.

Record the current state:

```bash
sudo cliproxy-manager check-update
sudo ss -ltnp | grep -E ':(8320|8317)'
sudo grep -n 'no-port-forwarding' /home/amtunnel/.ssh/authorized_keys || true
```

## 3. Upgrade

```bash
cd cliproxyapi-account-manager-easy-installer
git fetch --tags
git checkout main
git pull --ff-only
cd server-installer
sudo bash update.sh
```

If you are testing an unreleased branch, check out that branch instead. The updater uses the bundle shipped in the checkout.

The updater verifies the bundle hash, snapshots the old application, swaps in v1.0.1, enforces loopback, restarts, and polls `/api/health`. Security migrations run **only after** a healthy start.

### Expected output (abridged)

```text
[INFO] [1/4] Creating comprehensive pre-update snapshot...
[OK] Pre-update snapshot created at /var/backups/.../snapshot_...
[OK] Update bundle checksum verified.
[INFO] [2/4] Applying application update...
[OK] Enforced loopback bind (HOST=127.0.0.1) ...
[INFO] [3/4] Restarting service...
[INFO] [4/4] Verifying post-update health...
[INFO] Auditing and migrating SSH tunnel authorized_keys...
[OK] Migrated legacy v1.0.0 tunnel restrictions ...
[OK] Update completed and verified successfully!
```

## 4. Verify

```bash
sudo cliproxy-manager check
sudo cliproxy-manager check-update
sudo grep -n 'amtunnel' /home/amtunnel/.ssh/authorized_keys
sudo grep -n -A12 'Match User amtunnel' /etc/ssh/sshd_config
sudo sshd -t
sudo ss -ltnp | grep ':8320'
curl -s http://127.0.0.1:8320/api/health
```

Expected:

- one `amtunnel` key line, without `no-port-forwarding`;
- `permitopen="127.0.0.1:8320"` and `permitlisten="127.0.0.1:1"`;
- a `Match User amtunnel` block ending with `ForceCommand /bin/false`;
- `HOST=127.0.0.1` in `manager.env`;
- `/api/health` returns `"status":"healthy"`;
- `ss` shows `127.0.0.1:8320`, never `0.0.0.0`.

Then open the HAOS panel. If the add-on is still running from v1.0.0, its key remains valid; you only need to restart the add-on if it was in a failed state.

## 5. Manual key migration

Automatic migration covers the exact v1.0.0 form:

```text
command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320" ...
```

It does not rewrite custom lines for other targets. If your key differs, reinstall with the same public key:

```bash
sudo bash install.sh --setup-tunnel-user --tunnel-pubkey "ssh-ed25519 AAAA... amtunnel@haos"
```

Then remove the old line manually:

```bash
sudo cp -a /home/amtunnel/.ssh/authorized_keys /root/authorized_keys.bak
sudo nano /home/amtunnel/.ssh/authorized_keys
sudo sshd -t
```

Do not add `no-port-forwarding` and do not use `permitlisten="none"`; current OpenSSH rejects the key with `bad key options: invalid permission port`.

## 6. If the update fails

The updater restores the previous application tree and exits non-zero. It does not modify SSH access on failure, but it does keep the loopback rewrite.

```bash
sudo systemctl status cliproxyapi-account-manager --no-pager
sudo journalctl -u cliproxyapi-account-manager -n 200 --no-pager
ls -1 /var/backups/cliproxyapi-account-manager/
```

If the service is still unhealthy, follow
[OPERATIONS.md](OPERATIONS.md#recovering-from-a-failed-update).

## 7. Rollback to v1.0.0 (not recommended)

There is no supported downgrade flag. Restoring v1.0.0 reintroduces the broken tunnel key and weaker remote-forwarding controls. If you must:

1. stop the service;
2. restore the v1.0.0 application tree from your pre-upgrade archive;
3. restore `manager.env`, but keep `HOST=127.0.0.1`;
4. remove the managed `Match User amtunnel` block from `sshd_config`;
5. run `sshd -t`, reload SSH, and restart the service.

Treat this as an emergency action and re-upgrade as soon as the blocking issue is fixed.

## 8. HAOS add-on upgrade

The add-on version is `1.0.1`. In Home Assistant:

1. **Settings → Add-ons → Add-on Store → ⋮ → Check for updates**.
2. Open **CLIProxyAPI Account Manager Tunnel** and update.
3. Confirm your options survived: `server_host`, `server_port`, `server_user`, `remote_host`, `remote_port`, `host_key`.
4. Start the add-on and check the log for a pinned fingerprint and a connected tunnel.

The add-on keeps `/data` across updates, including `id_ed25519`, `known_hosts`, and `options.json`. If the host key changed, update `host_key`.

## 9. Known migration limitations

- The migration is line-based and preserves unrelated keys byte-for-byte. It does not deduplicate two different tunnel keys; remove retired keys manually.
- If `authorized_keys` is unreadable or unwritable, migration aborts and leaves the original file unchanged. The updater logs a warning.
- If `sshd_config` is managed by configuration management (Ansible, Puppet, cloud-init), your tool may overwrite the managed block. Re-run `install.sh` or encode the block in your configuration.
- The updater does not verify the CLIProxyAPI management API. The Account Manager can be healthy while provider operations fail; check CLIProxyAPI separately.
