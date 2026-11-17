# CLIProxyAPI Account Manager (application source)

This directory contains the **development source** of the Account Manager web application that is shipped as the runtime bundle in `../server-installer/embedded/cliproxyapi-account-manager-v1.0.3.tar.gz`.

It is based on the original CLIProxyAPI Account Manager by Antigravity Engineering (MIT). See [NOTICE.md](NOTICE.md).

## Layout

```text
src/                 HTTP server, auth, audit, auth store, provider adapters
public/              Vanilla HTML/CSS/JS dashboard
tests/               Node.js test runner suites (synthetic data only)
package.json         Application metadata, version 1.0.3
package-lock.json    Lockfile, version 1.0.3
```

## Local checks

```bash
cd account-manager
npm test
```

Tests use temporary directories and synthetic credentials only. No production token, account, or auth file is read or modified.

## Runtime contract

- Entry point: `src/server.js`
- Default port: `8320`
- Bind address: `127.0.0.1` (loopback only)
- Health endpoint: `/api/health`
- CLIProxyAPI target: `http://127.0.0.1:8317`
- Auth directory: `/var/lib/cliproxyapi/auths`
- Management API used for Pause/Resume: `PATCH /v8/management/credentials/status`

Do not run this directory directly on production. Production deployments use the verified runtime bundle through `server-installer/update.sh`.
