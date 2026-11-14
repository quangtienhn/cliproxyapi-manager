# Real Account Manager Loopback Verification

**Component:** the actual Account Manager application shipped in `server-installer/embedded/cliproxyapi-account-manager-v1.0.1.tar.gz`  
**Test:** `tests/test_real_service_loopback.js`  
**Environment:** Windows 11 audit host, Node.js v24.21.0  
**Label:** real shipped process, non-target OS  
**Date:** 2026-11-12

This test is deliberately not a generic "can Node bind to localhost" check. It extracts the embedded bundle, starts the real server, and inspects the real listening sockets. It is the closest available evidence to production loopback behavior short of a native Linux install.

---

## 1. Procedure

1. Extract the embedded application bundle and the bundled `yaml` dependency into a temporary directory.
2. Create an isolated config and data directory.
3. Start `src/server.js` with a free loopback port and `HOST=127.0.0.1`.
4. Poll `/api/health` until the process answers.
5. Inspect the listening sockets and compare the bound address.
6. Attempt connections from:
   - IPv4 loopback `127.0.0.1`;
   - IPv6 loopback `::1`;
   - every detected non-loopback host interface address.
7. Restart the process and repeat.
8. Repeat with `HOST=::1` to confirm explicit IPv6 loopback works without exposing IPv4.
9. Assert the shipped environment template cannot request a wildcard bind.

The test does not modify the host firewall, does not use a privileged port, and cleans up its temporary directory and process.

---

## 2. Results

All 16 assertions passed.

| Assertion group | Result |
| --- | --- |
| Fresh start answers on the configured loopback port | Pass |
| Listener is bound to `127.0.0.1` | Pass |
| No `0.0.0.0` or `[::]` listener exists | Pass |
| IPv4-loopback process is not reachable on `::1` | Pass |
| Every detected LAN address fails to reach the service | Pass |
| Restart reproduces the same binding invariants | Pass |
| Explicit `::1` configuration listens on IPv6 loopback only | Pass |
| IPv6-loopback process is not reachable on `127.0.0.1` | Pass |
| `manager.env.template` cannot request a wildcard bind | Pass |

LAN addresses are discovered from the host at runtime and are intentionally omitted from this report.

---

## 3. What this proves and what it does not

**Proves:**

- the bundled application honors `HOST` and does not silently bind wider;
- a wildcard listener is absent when loopback is configured;
- loopback traffic works;
- the process can restart and preserve the invariant;
- the shipped template is loopback-only.

**Does not prove:**

- behavior on native Debian or Ubuntu;
- behavior under systemd sandboxing;
- behavior when a user manually edits `manager.env` to a wildcard address (the installer rewrites it, but a manual edit is outside this test);
- behavior of CLIProxyAPI itself.

Those remain covered by documentation and, for real systems, by `cliproxy-manager check`.

---

## 4. How to reproduce on a Linux target

```bash
cd cliproxyapi-account-manager-easy-installer
node tests/test_real_service_loopback.js
```

On a Linux host, the test additionally exercises the host's real interface list. Record the platform and kernel in the release evidence.

For production verification after install:

```bash
sudo ss -ltnp | grep ':8320'     # expect 127.0.0.1:8320 only
curl -s http://127.0.0.1:8320/api/health
sudo cliproxy-manager check
```
