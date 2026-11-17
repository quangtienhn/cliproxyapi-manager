# Home Assistant OS Add-on Guide

> Production status: add-on `352ece41_cliproxyapi_am_tunnel` version `1.0.3` is installed and started, with Ingress enabled and the SSH tunnel verified connected. An older stopped add-on `local_cliproxyapi_am_tunnel` v1.0.0 was left untouched. See [../TX3_HAOS_DEPLOYMENT_COMPLETION_REPORT.md](../TX3_HAOS_DEPLOYMENT_COMPLETION_REPORT.md).

The add-on **CLIProxyAPI Manager Tunnel** publishes the Account Manager inside Home Assistant through Ingress. It does not expose a port to your LAN or WAN.

- Add-on slug: `cliproxyapi_am_tunnel`
- Architectures: `amd64`, `aarch64`
- Ingress: enabled, entry `/`, panel **Account Manager**
- Host ports published: none
- Persistent data: `/data`

## 1. Repository layout

```text
repository.yaml                     # marks this repo as an add-on repository
haos-addon/
  config.yaml                       # add-on metadata, options, schema
  build.yaml                        # base images
  Dockerfile                        # Alpine + openssh-client + nodejs
  icon.png                          # 256x256
  logo.png                          # 512x512
  translations/en.yaml              # option labels and help
  rootfs/
    run.sh                          # tunnel supervisor
    hostkey.mjs                     # host-key pinning
    proxy.mjs                       # Ingress reverse proxy
```

A Home Assistant add-on repository must have `repository.yaml` at the root and one directory per add-on with a `config.yaml`. The directory name is not the slug; `slug` in `config.yaml` is authoritative.

## 2. Install

1. **Settings → Add-ons → Add-on Store**.
2. **⋮ → Repositories**.
3. Add `https://github.com/quangtienhn/cliproxyapi-manager`.
4. Refresh the store and install **CLIProxyAPI Manager Tunnel**.

The Supervisor builds the image from `haos-addon/Dockerfile` using `build.yaml`. Build failures are usually caused by no network access to Alpine/APK or an unsupported architecture.

## 3. Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `server_host` | string | empty | DNS name or IP of the server running the Account Manager |
| `server_port` | port | `22` | SSH port on the server |
| `server_user` | string | `amtunnel` | Restricted tunnel account |
| `remote_host` | string | `127.0.0.1` | Destination as seen by the server; keep loopback |
| `remote_port` | port | `8320` | Account Manager port |
| `host_key` | string | empty | Full server SSH host public key line (required) |

`host_key` has no trust-on-first-use fallback. Get it from the server:

```bash
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare the fingerprint with a trusted source before pasting it.

`remote_host` is intentionally restricted in practice by the server-side `PermitOpen 127.0.0.1:8320`. If you set it to another address, the tunnel will fail. The add-on logs a warning instead of silently retrying forever.

## 4. First connection

On first start, the add-on:

1. creates `/data/id_ed25519` and `/data/id_ed25519.pub` if absent;
2. logs the **public** key and fingerprint (never the private key);
3. validates `host_key` and writes `/data/known_hosts`;
4. starts `ssh -N -L 127.0.0.1:18320:<remote_host>:<remote_port>`;
5. starts the Ingress proxy on `0.0.0.0:8080` inside the container.

Authorize the public key on the server:

```bash
cd cliproxyapi-manager/server-installer
sudo bash install.sh --setup-tunnel-user \
  --tunnel-pubkey "ssh-ed25519 AAAA... amtunnel@haos"
```

The add-on retries every five seconds. No restart is required.

## 5. How Ingress rewriting works

Home Assistant proxies panel requests under a path like `/api/hassio_ingress/<token>/`. The add-on:

- reads `X-Ingress-Path` (or the URL prefix) and strips it before forwarding;
- rewrites absolute URLs in HTML, JS, CSS, and JSON responses;
- rewrites cookie `Path=/` to the ingress prefix;
- rewrites relative `Location` redirects;
- strips hop-by-hop headers;
- adds `X-Forwarded-Host` and `X-Forwarded-Proto`.

Without these rewrites the Account Manager's absolute `/api/...` calls would bypass Ingress and fail.

The proxy listens on `0.0.0.0:8080` **inside the container only**. `config.yaml` has no `ports:` mapping, so the Supervisor does not publish it to the host. Do not add one.

## 6. Health and watchdog

- Internal: `http://127.0.0.1:8080/healthz`
- Supervisor watchdog: `http://[HOST]:[PORT:8080]/healthz`

Healthy response:

```json
{
  "status": "healthy",
  "tunnel": "connected",
  "configured": true,
  "target": "amtunnel@server.example.com",
  "timestamp": "..."
}
```

`503` with `"tunnel":"disconnected"` means the proxy is up but SSH or the Account Manager is unreachable. The panel shows a diagnostic page with the add-on public key.

Health results are cached for two seconds to avoid hammering the upstream.

## 7. Logs

Home Assistant → add-on → **Log**. Look for:

```text
SSH_PUBLIC_KEY=ssh-ed25519 AAAA... amtunnel@haos
SSH_FINGERPRINT=SHA256:...
Pinned host key fingerprint: SHA256:...
Connecting amtunnel@host:22 -> 127.0.0.1:8320 (local 127.0.0.1:18320)
```

On failure:

```text
SSH host key missing or invalid...
SSH tunnel disconnected (rc=255); reconnecting in 5s...
```

The log never contains the private key, the Account Manager password, or management secrets.

## 8. Updating and uninstalling

Update through the add-on store. `/data` is preserved, including the key pair and pinned host key. If the server host key changed, update `host_key`.

Uninstalling the add-on removes the container. `/data` may remain in the Supervisor's add-on data volume; if you need a fresh key, remove the add-on data before reinstalling, or delete `/data/id_ed25519*` from the container.

Removing the add-on does **not** revoke the key on the server. Remove the corresponding line from `/home/amtunnel/.ssh/authorized_keys`:

```bash
sudo nano /home/amtunnel/.ssh/authorized_keys
sudo ssh-keygen -lf /home/amtunnel/.ssh/authorized_keys
```

## 9. Security properties and limits

- Ingress access requires an authenticated Home Assistant session; the add-on has no separate login.
- The add-on is not reachable from the LAN or WAN; there is no host port.
- The SSH client uses public-key authentication only, with host key pinning and keepalives.
- The tunnel account cannot run commands, get a shell, allocate a PTY, forward to other ports, use Unix sockets, or create a server-side listener.
- The add-on does not verify CLIProxyAPI; it only reaches the Account Manager.
- Supervisor upgrades, Ingress token behavior, and watchdog timing were **not** exercised on a real Home Assistant OS installation during the v1.0.1 audit. The add-on structure and parser were validated locally.

## 10. Manual build (developers)

From a Linux host with Docker:

```bash
cd haos-addon
docker build \
  --build-arg BUILD_FROM=alpine:3.20 \
  -t cliproxyapi-am-tunnel:dev .
```

Run with a temporary data directory:

```bash
mkdir -p /tmp/am-data
docker run --rm -it \
  -v /tmp/am-data:/data \
  -p 127.0.0.1:8080:8080 \
  cliproxyapi-am-tunnel:dev
```

Mounting `8080` to `127.0.0.1` is only for local testing. Never publish the add-on port in production.

The optional Home Assistant base images are architecture-specific. `build.yaml` uses `alpine:3.20` for both targets, which is enough for this add-on because it installs only `openssh-client` and `nodejs` from APK.

## 11. Troubleshooting

See [../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md). The most common issues are a missing or mismatched `host_key`, an unauthorized tunnel key, and a wrong `server_host` or `server_port`.
