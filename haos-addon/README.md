# CLIProxyAPI Manager Tunnel (Home Assistant add-on)

Home Assistant OS add-on that exposes the CLIProxyAPI Manager through Ingress over a restricted SSH tunnel.

- Ingress panel, no published host ports
- Pinned server host key, public-key authentication only
- Server-side forwarding restricted to `127.0.0.1:8320`
- Automatic reconnect with keepalives
- `amd64` and `aarch64`

Install this repository as a custom add-on repository:

```text
https://github.com/quangtienhn/cliproxyapi-manager
```

Then see [DOCS.md](DOCS.md) for configuration and setup. Server-side installation lives in [../server-installer](../server-installer) and is documented in [../docs/INSTALLATION.md](../docs/INSTALLATION.md).

Requires the Account Manager server component and CLIProxyAPI. This add-on does not install either.
