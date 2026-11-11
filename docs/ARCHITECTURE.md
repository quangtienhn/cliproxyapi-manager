# Architecture & Security Model

## System Overview

```text
[ Home Assistant OS ]
        │
   (HA Ingress)
        │
 [ Local Add-on ]  ──(SSH Local Port Forward Tunnel)──>  [ Debian / Linux Server ]
                                                                 │
                                                       (127.0.0.1:8320)
                                                                 │
                                                    [ Account Manager Service ]
                                                                 │
                                                  (Loopback HTTP 127.0.0.1:8317)
                                                                 │
                                                      [ CLIProxyAPI Core ]
```

## Security Invariants

1. **Localhost Only**:
   - CLIProxyAPI management port is never exposed to WAN or LAN.
   - Account Manager is bound locally and proxied securely via SSH tunnel.
2. **Restricted SSH Access**:
   - `command="/bin/false"` ensures no interactive shell is spawned.
   - `no-pty`, `no-agent-forwarding`, `no-X11-forwarding`.
   - `permitopen="127.0.0.1:8320"` guarantees traffic can only reach the Account Manager.
3. **Protected Data & Credentials**:
   - OAuth JSON tokens under `/var/lib/cliproxyapi/auths` are preserved across all updates and uninstalls.
   - Backups strictly enforce permission `0600` on credentials.
   - Diagnostic tools redact all credentials and secrets before output.
