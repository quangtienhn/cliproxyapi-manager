# HAOS ADD-ON & INGRESS REVERSE PROXY INTEGRATION REPORT
> **Historical document (2026-11-11, v1.0.0 era).** Kept for audit trail. v1.0.1 replaced the inline host-key check with `rootfs/hostkey.mjs`, added strict fail-closed parsing, `UpdateHostKeys=no`, `VerifyHostKeyDNS=no`, cold backups, and removed private deployment fallbacks. The proxy test now allocates dynamic ports and a temporary data directory.

**Add-on Slug:** `cliproxyapi_am_tunnel`  
**Target Environment:** Home Assistant OS Supervised Add-on with Ingress  
**Verification Level:** Isolated Integration Testing & Concurrency Load Test  
**Date:** 2026-11-11  

---

## 1. Test Summary

| Capability / Scenario | Verification Mode | Actual Result | Status |
|---|---|---|---|
| **Ingress Path Prefix Rewriting** | Live HTTP Proxy (`tests/test_haos_proxy_live.js`) | Strips `/api/hassio_ingress/<token>` to upstream endpoints | **PASS** |
| **HTML Script & Link Rewriting** | Live HTTP Proxy | Prepends ingress prefix to `/app.js`, `/api/...`, `style.css` | **PASS** |
| **Cookie Path Preservation** | Live HTTP Proxy | Rewrites `Path=/` to `Path=/api/hassio_ingress/<token>/` | **PASS** |
| **HTTP 302 Redirect Location** | Live HTTP Proxy | Rewrites `Location: /api/accounts` to prefix URL | **PASS** |
| **Concurrent Load Handling** | 50 concurrent requests | 50/50 succeeded without socket exhaustion or timeout | **PASS** |
| **Health Watchdog (`/healthz`)** | Dynamic Upstream Cache | Returns 200 when upstream reachable, 503 when disconnected | **PASS** |
| **Host Key Validation & Pinning** | Unit / shell check | Strict validation against `known_hosts` | **PASS** |
| **Docker Build Multi-Arch** | Dockerfile analysis | Node 22 + Alpine 3.20 + OpenSSH client | **PARTIALLY VERIFIED** (Host lacks local Docker engine) |

---

## 2. Docker & Supervisor Operational Boundaries
- The add-on runs `run.sh` as an init container, automatically generating a dedicated `id_ed25519` keypair inside HAOS `/data`.
- Private keys are never exported or printed into Supervisor logs; only `SSH_PUBLIC_KEY` is logged for administrative convenience.
- Supervisor integration utilizes `ingress: true` on `ingress_port: 8080`, removing any requirement to open host ports on HAOS.
