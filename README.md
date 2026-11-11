# CLIProxyAPI Account Manager Easy Installer v1.0.0

A safe, automated, and hardened installer and manager for CLIProxyAPI Account Manager on Debian/Linux servers with seamless Home Assistant OS Ingress integration.

## Features

- **Automated Server Installation**: Supports Debian 12/13 (AMD64 & ARM64) and Ubuntu LTS.
- **Unified Management CLI**: `cliproxy-manager` for install, check, update, backup, restore, diagnostics, and uninstall.
- **Home Assistant OS Tunnel Add-on**: Secure access from the HAOS dashboard via SSH port forwarding and Ingress rewriting.
- **Enterprise-Grade Security**:
  - Loopback-only Management API isolation.
  - Restricted SSH keys (`command="/bin/false"`, `permitopen="127.0.0.1:8320"`, `no-pty`).
  - Automatic secret redaction in logs and diagnostic outputs.
  - Strict file permissions (`0600` for credentials, `0700` for data/backup roots).
- **OAuth Safety**: Preserves existing authentication tokens during updates, restores, and uninstalls.
- **Safe Updates & Rollback**: Automatic pre-upgrade snapshots with atomic rollback on failure.

## Quick Start

### 1. Server Installation (Debian/Linux AMD64 or ARM64)

```bash
git clone https://github.com/quangtienhn/cliproxyapi-account-manager-easy-installer.git
cd cliproxyapi-account-manager-easy-installer/server-installer
sudo bash install.sh
```

### 2. Home Assistant OS Add-on

- Copy or register the `haos-addon` directory in your Home Assistant Add-on repository.
- Configure `server_host` and `host_key`.
- Start the add-on and access Account Manager via the Home Assistant sidebar!

## Documentation

- [Installation Guide](docs/INSTALLATION.md)
- [Operations & Maintenance](docs/OPERATIONS.md)
- [Architecture & Security Model](docs/ARCHITECTURE.md)
- [Security Policy](SECURITY.md)

## License

MIT License. See [LICENSE](LICENSE) for details.
