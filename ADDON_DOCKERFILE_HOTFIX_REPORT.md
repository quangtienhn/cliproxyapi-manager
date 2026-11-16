# ADDON DOCKERFILE HOTFIX REPORT

## Root cause

HAOS build failed with:

```
COPY rootfs /  # s6-overlay service definitions under etc/s6-overlay
ERROR: lstat /#: no such file or directory
```

Docker's parser treated the trailing inline comment as part of the `COPY` source
path (`/#`), so the build looked for a path named `/#`.

## Fix

In `haos-addon/Dockerfile`, replaced:

```dockerfile
COPY rootfs /  # s6-overlay service definitions under etc/s6-overlay
```

with:

```dockerfile
# Copy s6-overlay service definitions
COPY rootfs /
```

No other Dockerfile changes. s6 service layout, `/init`, run script, SSH tunnel,
Ingress, options, and user config are unchanged.

## Version

- Add-on version: `1.0.2` -> `1.0.3`
- Updated: `haos-addon/config.yaml`, `haos-addon/CHANGELOG.md`, `CHANGELOG.md`.
- Embedded bundle: not regenerated (server-installer content unchanged; per
  instruction, no fake artifact created).

## Validation

- Dockerfile static: `COPY`/`RUN` directives valid; comment moved to its own line.
- `test_repo_hygiene.js`: 57 passed, 2 failed.
  - The 2 failures are `bundle cliproxyapi-account-manager-v1.0.3.tar.gz exists`
    and `bundle checksum file exists`, because no v1.0.3 bundle was created
    (by design, per "do not create fake artifact"). These are the only failures.
- YAML validation: OK.
- Docker build: **NOT_TESTED** (no Docker in this environment).

## Git

- Working on `main`, commit + push performed.
- Repository visibility set to PUBLIC per user request (was PRIVATE).
- No release/tag created.

## Commit

See git log on `main`.
