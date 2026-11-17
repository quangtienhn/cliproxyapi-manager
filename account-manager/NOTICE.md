# Account Manager attribution

The application in this directory is based on the original **CLIProxyAPI Account Manager** authored by **Antigravity Engineering** and distributed under the MIT License (as recorded in the original `package.json`).

This repository keeps that attribution. The original author, package name and MIT license are preserved in `package.json` and `package-lock.json`.

Extensions and fixes added in this repository after the original release:

- Safe Gemini/Antigravity account deletion for auth filenames containing `@` and `+`, with strict path and credential-file validation.
- Clear separation of validation, not-found and filesystem errors on delete; no unnecessary backup for invalid targets.
- Per-account Pause / Resume using the CLIProxyAPI v8 Management API native `disabled` flag.
- Dashboard status badges and Active / Paused counters.
- Correct handling of the top-level `disabled` field written by CLIProxyAPI v8.
- Runtime bundle alignment to version 1.0.3.

CLIProxyAPI itself is a separate upstream project by router-for-me and is **not** included here.

See the repository root [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) for bundled dependency licenses.
