# Installation Guide

## Quick Start (Debian/Linux)

The Easy Installer provides a single command to set up CLIProxyAPI Account Manager:

```bash
git clone https://github.com/quangtienhn/cliproxyapi-account-manager-easy-installer.git
cd cliproxyapi-account-manager-easy-installer/server-installer
sudo bash install.sh
```

### Installation Options

- `--non-interactive`: Run with defaults without user interaction.
- `--dry-run`: Validate environment without modifying files or systemd.
- `--setup-tunnel-user`: Create dedicated restricted SSH user (`amtunnel`).
- `--tunnel-pubkey "ssh-ed25519 ..."`: Authorize HAOS Add-on public key automatically.

## Home Assistant OS Integration

1. In Home Assistant, navigate to **Settings > Add-ons > Add-on Store**.
2. Add this repository as a custom repository or copy `haos-addon` into `/addons/cliproxyapi_am_tunnel`.
3. Install **CLIProxyAPI Account Manager Tunnel**.
4. In the Add-on Configuration tab:
   - `server_host`: IP address of your Debian/Linux server (e.g. `192.168.1.133`)
   - `server_port`: SSH port (default `22`)
   - `server_user`: Tunnel user (default `amtunnel`)
   - `host_key`: Server SSH public host key (from `/etc/ssh/ssh_host_ed25519_key.pub`)
5. Start the add-on. Open **Account Manager** from your sidebar via Ingress.
