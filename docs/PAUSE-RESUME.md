# Pause / Resume Accounts

The Account Manager can temporarily disable a provider account without deleting it. This is implemented through CLIProxyAPI's native credential status API, not by hiding rows in the UI.

## What Pause does

- Sends `PATCH /v8/management/credentials/status` to CLIProxyAPI with `{"name":"<auth file>","disabled":true}`.
- CLIProxyAPI writes a top-level `disabled: true` into the auth file and reloads its credential set.
- The account is no longer selected for new requests.
- The auth file, access token, refresh token, and all account metadata remain intact.
- The dashboard badge changes to `Paused`; `Active Accounts` decreases and `Paused Accounts` increases.

A request already in progress when Pause is confirmed may finish. Pause prevents new use, not cancellation of in-flight work.

## What Resume does

- Sends the same API call with `disabled: false`.
- CLIProxyAPI clears the disabled flag and makes the credential selectable again.
- No re-authentication is needed while the underlying credential is still valid.
- If the management key is missing, CLIProxyAPI is unreachable, or the state cannot be verified, an error is shown and the credential is left unchanged.

## How to use it

1. Open the Account Manager dashboard through Home Assistant Ingress.
2. Find the account row and its `Status` badge.
3. Click **Pause** on an Active account, or **Resume** on a Paused account.
4. Confirm the prompt when pausing. The result appears in the alert area and the list refreshes automatically.
5. **Delete** remains a separate action and works for both Active and Paused accounts.

## Compatibility notes

- Requires `CLIPROXYAPI_MANAGEMENT_KEY` in `/etc/cliproxyapi-account-manager/manager.env` and CLIProxyAPI `PATCH /v8/management/credentials/status` (available in v8.0.61).
- CLIProxyAPI must be reachable at `CLIPROXYAPI_URL` (normally `http://127.0.0.1:8317`). Keep `management.allow-remote: false` and bind CLIProxyAPI to loopback.
- CLIProxyAPI v8 writes the authoritative flag at the **top level** of the auth file and may leave an older `metadata.disabled` value untouched. Account Manager v1.0.3 reads the top-level flag first.
- Existing accounts without any disabled flag default to Active. No migration is required.

## Deleting Gemini / Antigravity accounts

Gemini (Antigravity) credentials are stored as `antigravity-<email>.json`, so filenames legitimately contain `@` and may contain `+`. Account Manager v1.0.3 accepts those characters while still rejecting path traversal, shell metacharacters, hidden files, symlinks, and non-credential JSON files. Delete returns distinct errors for missing/invalid filenames, not-found accounts, and filesystem failures, and only creates a backup after the target has been validated and found.
