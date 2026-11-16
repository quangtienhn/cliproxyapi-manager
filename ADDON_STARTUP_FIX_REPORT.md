# ADDON STARTUP FIX REPORT

## Root cause

The HAOS add-on image was built on a plain `alpine:3.20` base with `CMD ["/run.sh"]`
and `init: true`. HAOS runs add-on containers using the image's init mechanism;
with the previous layout the container ended up invoking `s6-overlay-suexec` outside
of PID 1, producing:

```
s6-overlay-suexec: fatal: can only run as pid 1
```

The add-on also did not declare an s6 service, so s6-overlay (present on HA base
images) had no service to supervise.

## Changes made

- `haos-addon/build.yaml`: base image changed from `alpine:3.20` to
  `ghcr.io/home-assistant/{arch}-base:3.20` (HA base image, provides s6-overlay).
- `haos-addon/Dockerfile`: added s6 service layout via `COPY rootfs /`; kept
  explicit `COPY rootfs/{run.sh,proxy.mjs,hostkey.mjs}` for hygiene test; removed
  `CMD` so the HA base image runs s6 `/init` as PID 1; no ENTRYPOINT override.
- `haos-addon/config.yaml`: `init: true` -> `init: false` (s6 manages init).
- `haos-addon/rootfs/etc/s6-overlay/s6-rc.d/cliproxyapi_tunnel/`: added `type`
  (longrun), `run` (exec /run.sh), and `user/contents.d/cliproxyapi_tunnel`
  marker so s6 supervises the tunnel.
- `haos-addon/CHANGELOG.md`: documented the fix under 1.0.1 (unreleased).

Functionality (SSH tunnel, Ingress proxy, host-key pinning, config schema) is
unchanged. Service name and slug unchanged for compatibility.

## Build / test status

- No Docker available in this environment, so the image was **not** built here.
- `tests/test_repo_hygiene.js`: 65 passed, 0 failed after changes.
- `haos-addon/config.yaml`: YAML valid.
- Icon/logo PNGs: valid (256x256, 512x512).

## Required on-device verification (HAOS)

1. Rebuild the add-on image on HAOS (Supervisor -> Rebuild, or `ha addons rebuild`).
2. Start the add-on and inspect logs: must not contain
   `s6-overlay-suexec: fatal: can only run as pid 1`.
3. Confirm PID 1 is `/init` (s6) and the tunnel service is supervised:
   `docker exec <container> ps -p 1 -o comm= ; docker exec <container> s6-rc -a list`.
4. Confirm `/run.sh` runs as the service process and the proxy listens on 8080.
5. Confirm SSH tunnel connects to the configured server.
6. Confirm Ingress (`/`) returns the Account Manager.

If any step fails, do not mark PASS; collect redacted logs and report.

## Rollback

Revert the Dockerfile/config.yaml/build.yaml/s6-rc.d changes and rebuild. The
previous image (alpine base) can be restored from git. No user data, SSH keys,
or host keys are touched by this change.
