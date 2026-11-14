# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x | Yes |

## Reporting a vulnerability

Please do **not** open a public issue for a security problem.

Use GitHub's private vulnerability reporting on this repository (**Security → Report a vulnerability**) and include:

- affected version, component, and platform;
- reproduction steps or a proof of concept;
- impact assessment;
- whether the issue requires local access, the tunnel key, or the Account Manager session.

You can expect an acknowledgement within seven days and a status update within thirty days. Please allow time for a fix before public disclosure.

For the current evidence index and residual risks, see [reports/PUBLICATION-SECURITY-AUDIT.md](reports/PUBLICATION-SECURITY-AUDIT.md) and [reports/PUBLIC-RELEASE-READINESS.md](reports/PUBLIC-RELEASE-READINESS.md).

Never send production credentials, OAuth tokens, private keys, hostnames, or IP addresses. Redact logs before attaching them.

## Security model

### 1. Loopback-only management plane

- CLIProxyAPI Management API listens on `127.0.0.1:8317` with `management.allow-remote: false`.
- Account Manager listens on `127.0.0.1:8320`. The shipped `manager.env` template sets `HOST=127.0.0.1`, and `install.sh`, `update.sh`, and `restore.sh` rewrite a legacy `HOST=0.0.0.0` back to loopback.
- No installer step opens a firewall port or creates a WAN listener.
- The HAOS add-on uses Ingress only; `config.yaml` has no `ports:` mapping, so the Supervisor does not publish a host port for it.

### 2. Least-privilege SSH tunnel

The tunnel account (`amtunnel` by default) is a system account with `/bin/false` as its shell. Its `authorized_keys` entry is:

```text
command="/bin/false",no-agent-forwarding,no-pty,no-user-rc,no-X11-forwarding,permitopen="127.0.0.1:8320",permitlisten="127.0.0.1:1" <PUBLIC KEY>
```

Key options are only one layer. The installer also appends a managed block to the system `sshd_config`:

```text
Match User amtunnel
    AllowTcpForwarding local
    AllowStreamLocalForwarding no
    PermitOpen 127.0.0.1:8320
    PermitListen none
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForceCommand /bin/false
```

Consequences:

- Local TCP forwarding to `127.0.0.1:8320` works.
- Local forwarding to any other host, port, or Unix socket is refused.
- Remote forwarding (`ssh -R`) is refused by `PermitListen none`, regardless of the requested listen address or port.
- Shell, remote command, PTY, agent, X11, password, and keyboard-interactive authentication are refused.

The `permitlisten="127.0.0.1:1"` key option is retained as defence in depth, but it is **not** relied on as a complete remote-forwarding prohibition. Port 1 on loopback can be bound by the account in some configurations if the server policy is removed; the `Match` block is what makes remote forwarding impossible.

`permitlisten="none"` is not valid inside `authorized_keys` on current OpenSSH; using it causes the key to be rejected.

### 3. Host key pinning

The HAOS add-on requires a `host_key` option and writes a `known_hosts` file with:

- `StrictHostKeyChecking=yes`
- `UserKnownHostsFile` pointing at the pinned file
- `GlobalKnownHostsFile=/dev/null`
- `UpdateHostKeys=no`
- `VerifyHostKeyDNS=no`

Empty, malformed, mismatched, or missing pins cause the connection to fail closed.

### 4. Secret handling

- Management secrets and OAuth tokens are never accepted as command-line arguments.
- `manager.env` is `0640` and owned by `root:cliproxyapi`; backup roots are `0700`, credential files `0600`.
- `diagnostics.sh` prints a redacted view of configuration files. Redaction covers secret/password/token/key assignments, bearer tokens, and GitHub tokens.
- The installer does not log private keys. The HAOS add-on logs only the **public** key and its fingerprint.
- Backups contain credentials and must be stored accordingly. They are not encrypted by this project; use full-disk encryption or an encrypted archive if the backup medium is not trusted.

### 5. Safe lifecycle operations

- `update.sh` verifies the embedded bundle SHA-256 before use, snapshots the application tree, and rolls back on health-check failure or service restart failure.
- Security migrations (restricted key, sshd policy) run **after** the new version is proven healthy, so a failed update never changes SSH access.
- `restore.sh` verifies every backup file against `SHA256SUMS.txt` before writing, creates a pre-restore safety copy, and re-enforces loopback binding after restoring a v1.0.0 configuration.
- `uninstall.sh` preserves data by default. `--purge-data` removes Account Manager data plus the managed tunnel key and sshd policy; it still preserves backups.
- `sshd_config` and `authorized_keys` edits are backed up, validated with `sshd -t`, and the SSH service is reloaded rather than restarted. A failed reload restores the previous file.

## Known limitations

- The per-user sshd policy is appended to the main `sshd_config`, not to `sshd_config.d/`. A trailing `Match` block in an included file can change the scope of later directives, so the main file is the safe location.
- Host key pinning requires the administrator to transfer the server public key out of band. The add-on deliberately has no "trust on first use" mode.
- The project does not manage the host firewall. If an administrator independently publishes `8320`, that exposure is outside this installer's control; `cliproxy-manager check` warns about wildcard listeners.
- CLIProxyAPI is a separate project. Its configuration and any `allow-remote` change are the operator's responsibility.
- The Account Manager is an administrative UI. Treat access to it as equivalent to access to your provider credentials.

## Hardening checklist for operators

1. Keep `management.allow-remote: false`.
2. Do not add a firewall rule or reverse proxy that publishes `8320`.
3. Use a unique SSH key for the tunnel; do not reuse an administrator key.
4. Verify the server host key fingerprint over a trusted channel before pasting it into Home Assistant.
5. Run `sudo cliproxy-manager check` after every update, reboot, or network change.
6. Store backups encrypted and off-host.
7. Remove the tunnel account and managed sshd policy with `uninstall.sh --purge-data` when decommissioning.
