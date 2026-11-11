# Security Policy

## Security Model

CLIProxyAPI Account Manager Easy Installer orchestrates deployment of CLIProxyAPI and its Account Manager under strict security guarantees:

1. **Local Loopback Isolation**:
   - CLIProxyAPI Management API (`/management`) runs strictly on `127.0.0.1:8317` with `allow-remote: false`.
   - Account Manager runs locally on `127.0.0.1:8320` bound to localhost.
   - Remote access from Home Assistant OS occurs strictly via SSH local port forwarding tunnel.

2. **Least Privilege SSH Tunnel**:
   - The dedicated tunnel user (`amtunnel`) has no interactive shell (`/bin/false` or `/usr/sbin/nologin`).
   - SSH `authorized_keys` restricts connections to:
     `command="/bin/false",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320"`
   - Host key verification is strictly enforced (`StrictHostKeyChecking=yes`).

3. **Secret Protection**:
   - Management API keys and OAuth tokens are never exposed in logs, CLI arguments, or network transfers.
   - Backup files containing configuration or credentials are created with permission `0600` / directories `0700`.
   - Diagnostic reports redact sensitive values (passwords, tokens, management keys).

## Reporting a Vulnerability

If you discover a security issue or vulnerability:
- Please open a private security advisory on GitHub or contact the repository maintainers.
- Do not disclose security vulnerabilities publicly before a fix and release are available.
