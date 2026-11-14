# CLIProxyAPI Account Manager Tunnel

This add-on exposes the CLIProxyAPI Account Manager running on a separate Debian/Ubuntu server through a restricted SSH tunnel and the Home Assistant Ingress panel.

## Requirements

- Home Assistant OS on `amd64` or `aarch64`.
- The Account Manager installed on the server with `--setup-tunnel-user`.
- The server's SSH host public key, obtained over a trusted channel.

## Configuration

| Option | Required | Default | Notes |
| --- | --- | --- | --- |
| `server_host` | yes | - | Server DNS name or IP |
| `server_port` | no | `22` | SSH port |
| `server_user` | no | `amtunnel` | Restricted tunnel account |
| `remote_host` | no | `127.0.0.1` | Keep loopback |
| `remote_port` | no | `8320` | Account Manager port |
| `host_key` | yes | - | Full server host public key line |

Get the host key on the server:

```bash
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
```

Paste the entire line into `host_key`. The add-on does not trust unknown keys.

## Setup

1. Start the add-on with `host_key` set.
2. Open the add-on log and copy the `SSH_PUBLIC_KEY=...` line.
3. Authorize it on the server:

   ```bash
   cd cliproxyapi-account-manager-easy-installer/server-installer
   sudo bash install.sh --setup-tunnel-user \
     --tunnel-pubkey "ssh-ed25519 AAAA... amtunnel@haos"
   ```

4. Wait up to five seconds. Open **Account Manager** in the sidebar.
5. Create the administrator password on first visit.

## Data and backups

- `/data/id_ed25519` - add-on private key, generated on first start.
- `/data/id_ed25519.pub` - public key to authorize on the server.
- `/data/known_hosts` - pinned server host key.
- `/data/options.json` - Supervisor-provided options.

The add-on declares `backup: cold`; Home Assistant stops it before backing up `/data`.

## Security

- No host ports are published.
- Access is only through authenticated Home Assistant Ingress.
- SSH uses public-key authentication only.
- Host keys are pinned; empty, malformed, and mismatched keys fail closed.
- The server-side key and sshd policy permit exactly one forward: `127.0.0.1:8320`.
- Shell, PTY, agent, X11, Unix-socket, and remote forwarding are denied.

## Troubleshooting

Open the add-on log first. The panel itself shows a diagnostic page when the tunnel is down, including the add-on public key.

Common causes:

- `host_key` missing or stale after a server rebuild;
- the public key was never added on the server;
- wrong `server_host`/`server_port`;
- server SSH unreachable from Home Assistant OS.

Full guide: <https://github.com/quangtienhn/cliproxyapi-account-manager-easy-installer/blob/main/docs/TROUBLESHOOTING.md>
