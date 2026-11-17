# Troubleshooting

Start with:

```bash
sudo cliproxy-manager check
sudo cliproxy-manager diagnostics > /tmp/am-diag.txt
sudo journalctl -u cliproxyapi-account-manager -n 200 --no-pager
```

Review diagnostics before sharing. It is redacted, but pattern-based redaction is not a guarantee.

## The Account Manager page is blank or the add-on shows "SSH tunnel not connected"

The add-on's down page lists the target, whether `host_key` is set, and the add-on public key.

Check on the server:

```bash
sudo systemctl status ssh --no-pager
sudo systemctl status cliproxyapi-account-manager --no-pager
sudo ss -ltnp | grep ':22'
sudo ss -ltnp | grep ':8320'
sudo tail -n 50 /var/log/auth.log      # Debian/Ubuntu: sshd authentication messages
```

Check the add-on log in Home Assistant. Common causes:

| Log message | Cause | Fix |
| --- | --- | --- |
| `SSH host key missing or invalid` | `host_key` empty or malformed | Paste the full `ssh-ed25519 ...` line from `/etc/ssh/ssh_host_ed25519_key.pub` |
| `Host key verification failed` | Pinned key does not match the server | Re-read the current host key and update `host_key` |
| `Permission denied (publickey)` | Add-on key not in `authorized_keys` | Re-run `install.sh --setup-tunnel-user --tunnel-pubkey "..."` |
| `remote port forwarding failed` | A key contains `permitlisten="none"` or an invalid option | Remove that key; current installer never writes `permitlisten="none"` |
| `Connection refused` | Wrong host, port, or SSH not running | Check `server_host`, `server_port`, and `sshd` |
| `Connection timed out` | Routing or firewall between HAOS and server | Test SSH from another host on the same network |
| Page returns 502 but SSH connects | Account Manager not listening on `8320` | `systemctl restart cliproxyapi-account-manager`; check `journalctl` |

The add-on retries every five seconds after a disconnect. It does not need a restart after you authorize the key.

## Local health check fails

```bash
curl -v http://127.0.0.1:8320/api/health
sudo systemctl status cliproxyapi-account-manager --no-pager
sudo journalctl -u cliproxyapi-account-manager -n 100 --no-pager
```

| Symptom | Likely cause |
| --- | --- |
| `Connection refused` | Service stopped, wrong port, or bound to another address |
| `EADDRINUSE` in journal | Another process owns 8320 |
| `Cannot find module 'yaml'` | Bundled dependency missing; reinstall or re-extract |
| Process exits immediately | Invalid `manager.env`; inspect journal |

Reinstall the application without touching config:

```bash
cd cliproxyapi-manager/server-installer
sudo bash install.sh
```

## Port 8320 is listening on 0.0.0.0

This is a security defect, not a convenience setting.

```bash
grep -n '^HOST=' /etc/cliproxyapi-account-manager/manager.env
sudo sed -i 's/^HOST=.*/HOST=127.0.0.1/' /etc/cliproxyapi-account-manager/manager.env
sudo systemctl restart cliproxyapi-account-manager
sudo ss -ltnp | grep ':8320'
```

`install.sh`, `update.sh`, and `restore.sh` do this automatically. If it recurs, check for a configuration management tool or a restored file outside this installer.

## Tunnel connects but the UI cannot call the API

Symptoms: page loads, login or account actions fail, browser console shows 404/502 for `/api/...`.

- Confirm the add-on is current; older proxies did not rewrite Ingress paths correctly.
- Confirm you are opening the panel through Home Assistant, not directly at `:8080`.
- Check the add-on log for upstream errors.
- Verify CLIProxyAPI is running:

  ```bash
  sudo systemctl status cliproxyapi --no-pager
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8317/
  ```

## Account operations fail with management API errors

The Account Manager needs the CLIProxyAPI management secret.

```bash
sudo grep -n 'management' /etc/cliproxyapi/config.yaml
sudo grep -n '^CLIPROXYAPI_MANAGEMENT_KEY=' /etc/cliproxyapi-account-manager/manager.env
```

`manager.env` is `0640` and may require root to read. The value must match `management.secret-key` in the CLIProxyAPI config and must not be printed into tickets or chat.

Re-run synchronization:

```bash
cd cliproxyapi-manager/server-installer
sudo bash install.sh
```

If `CLIPROXYAPI_MANAGEMENT_KEY` is still empty, the CLIProxyAPI config is not at `/etc/cliproxyapi/config.yaml` or lacks `management.secret-key`.

## First-time setup says the administrator already exists

The admin state lives in `/var/lib/cliproxyapi-account-manager/admin.json`. If you lost the password and accept resetting access:

```bash
sudo systemctl stop cliproxyapi-account-manager
sudo mv /var/lib/cliproxyapi-account-manager/admin.json \
  /var/lib/cliproxyapi-account-manager/admin.json.bak.$(date +%Y%m%dT%H%M%S)
sudo systemctl start cliproxyapi-account-manager
```

The next visit shows the setup form. Sessions in other browsers remain valid until they expire. This does not affect provider credentials.

## Update failed and the service is down

The updater attempts an automatic rollback and prints the snapshot path. See [OPERATIONS.md](OPERATIONS.md#recovering-from-a-failed-update).

If SSH still works but the service does not, restore the last backup:

```bash
sudo cliproxy-manager restore
```

## Update failed before changing anything

A checksum error means the checkout is corrupted:

```bash
cd cliproxyapi-manager
git status
git pull --ff-only
sha256sum -c server-installer/embedded/SHA256SUMS-v1.0.3.txt
```

The checksum file is relative to `server-installer/embedded/`; run `cd server-installer/embedded` first if your `sha256sum` does not accept the path form.

## SSH key migration did not run

Check the key manually:

```bash
sudo cat /home/amtunnel/.ssh/authorized_keys
sudo grep -n 'Match User amtunnel' /etc/ssh/sshd_config
```

A v1.0.0 key contains `no-port-forwarding`. Remove that option only, keeping `permitopen`. Safer: reinstall with the same public key, which appends a corrected line, then delete the old line.

## `sshd` fails to reload after an install

The installer validates with `sshd -t` and restores the previous file if validation or reload fails. Confirm the live config is valid:

```bash
sudo sshd -t
sudo systemctl status ssh --no-pager
```

Timestamped backups are at `/etc/ssh/sshd_config.cliproxyapi.bak.*`. Do not copy a backup over the live file without running `sshd -t` first.

## HAOS add-on will not install or build

- Confirm the repository URL is exactly
  `https://github.com/quangtienhn/cliproxyapi-manager`.
- The repository root must contain `repository.yaml`; the add-on directory must contain `config.yaml`, `Dockerfile`, and `build.yaml`.
- Supervisor builds need network access to Alpine and APK repositories.
- Architecture must be `amd64` or `aarch64`; 32-bit ARM and i386 are unsupported.

If the build log shows a missing file, verify the checkout contains `haos-addon/rootfs/hostkey.mjs` and that `Dockerfile` copies it.

## Add-on health endpoint

Inside the container:

```bash
curl -s http://127.0.0.1:8080/healthz
```

Healthy:

```json
{"status":"healthy","tunnel":"connected","configured":true,...}
```

Home Assistant uses the same endpoint for the watchdog.

## Still stuck

Collect:

1. `sudo cliproxy-manager check` output.
2. Sanitized add-on log lines around a failed connection.
3. `sudo sshd -T | grep -E 'allowtcpforwarding|permitopen|permitlisten|allowstreamlocalforwarding'` (shows effective global values, not the per-user block).
4. The exact tunnel key line with the base64 key replaced by `REDACTED`.
5. Server OS, architecture, Node version, and add-on version.

Open an issue with the bug template. Do not include real hostnames, public IPs, tokens, or private keys.
