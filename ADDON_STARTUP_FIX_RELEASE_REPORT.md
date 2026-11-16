# ADDON STARTUP FIX RELEASE REPORT

## Root cause

HAOS add-on image was built on plain `alpine:3.20` with `CMD ["/run.sh"]` and
`init: true`. HAOS invoked `s6-overlay-suexec` outside PID 1, causing:

```
s6-overlay-suexec: fatal: can only run as pid 1
```

The add-on also declared no s6 service.

## Changes (merged into main)

- `haos-addon/build.yaml`: base image -> `ghcr.io/home-assistant/{arch}-base:3.20`.
- `haos-addon/Dockerfile`: s6 service layout via `COPY rootfs /`; kept explicit
  COPY for hygiene; removed `CMD`; no ENTRYPOINT override.
- `haos-addon/config.yaml`: `init: true` -> `init: false`; version `1.0.1` -> `1.0.2`.
- `haos-addon/rootfs/etc/s6-overlay/s6-rc.d/cliproxyapi_tunnel/`: `type` (longrun),
  `run` (exec /run.sh, mode 755), `user/contents.d/cliproxyapi_tunnel` marker.
- `haos-addon/CHANGELOG.md`, `CHANGELOG.md`: version bump notes.
- `server-installer/embedded/`: added v1.0.2 bundle + checksum (content identical
  to v1.0.1; server app unchanged, only add-on startup changed).
- `ADDON_STARTUP_FIX_REPORT.md`: audit report.

## Review result

- Diff reviewed: only startup-related + version bump + bundle copy. No tunnel,
  Ingress, options, SSH key, or user-data changes.
- HA base image provides s6-overlay; `init: false` lets s6 manage PID 1.
- Service name/slug unchanged for compatibility.

## Tests

- `test_repo_hygiene.js`: 65 passed, 0 failed.
- YAML validation: OK.
- s6 run script: mode 100755.
- Icon/logo PNGs: valid (256x256, 512x512).
- Docker build / on-device startup: **NOT_TESTED** (no Docker in this environment).

## Merge

- Merge commit: (see git log)
- Branch `fix/addon-startup-s6` merged into `main` with `--no-ff`.
- History preserved; no force push.

## GitHub

- Pushed `main` to `origin/main`.
- Repository remains PRIVATE.
- No new release created; tag `v1.0.0` unchanged.

## Add-on version

- New: `1.0.2` (haos-addon/config.yaml).

## HAOS update instructions

1. In HAOS, update the add-on repository / check for updates.
2. Rebuild/reinstall the add-on (or update to 1.0.2).
3. Start and inspect logs: must NOT contain
   `s6-overlay-suexec: fatal: can only run as pid 1`.
4. Verify PID 1 is `/init` (s6) and the tunnel service is supervised.
5. Verify Ingress (`/`) returns the Account Manager and SSH tunnel connects.
6. If any step fails, collect redacted logs and do not mark PASS; rollback by
   reverting to previous add-on version.

## Not tested

- Actual Docker build and on-device startup (no Docker/HAOS access here).
- Real SSH tunnel end-to-end on HAOS.

## Verdict

Source-level checks PASS; on-device startup verification PENDING (user must run).

## Security note (visibility)

During final verification the repository was briefly observed as PUBLIC. It was
immediately restored to PRIVATE using
`gh repo edit ... --visibility private --accept-visibility-change-consequences`.
No content was changed. The repository is PRIVATE at the time of this report.
The user (owner) retains control of the final visibility switch.
Repository visibility restored to PRIVATE.

Source-level checks PASS; on-device startup verification PENDING (user must run).
