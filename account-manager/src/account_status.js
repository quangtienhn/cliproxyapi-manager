import { validateAuthFilename } from './auth_store.js';

// Thin client for the CLIProxyAPI v8 Management API status endpoint.
// This is the native, supported way to disable a credential: CLIProxyAPI
// persists `metadata.disabled` in the auth file and its watcher reloads the
// runtime credential set. Account Manager never edits the auth file itself
// for pause/resume, so tokens and refresh tokens are left untouched.

export const ManagementErrorCode = Object.freeze({
  INVALID_FILENAME: 'INVALID_FILENAME',
  KEY_MISSING: 'MANAGEMENT_KEY_MISSING',
  ACCOUNT_NOT_FOUND: 'ACCOUNT_NOT_FOUND',
  API_ERROR: 'MANAGEMENT_API_ERROR',
  TIMEOUT: 'MANAGEMENT_TIMEOUT',
  UNAVAILABLE: 'MANAGEMENT_UNAVAILABLE',
  ALREADY_PAUSED: 'ALREADY_PAUSED',
  NOT_PAUSED: 'NOT_PAUSED',
  VERIFY_FAILED: 'STATE_VERIFICATION_FAILED'
});

export class ManagementError extends Error {
  constructor(code, message, httpStatus = 502) {
    super(message);
    this.name = 'ManagementError';
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

// Upstream error strings are untrusted and must never echo secrets or grow
// unbounded in an alert shown in the UI.
function sanitizeUpstreamText(text, maxLength = 180) {
  return String(text || '')
    .replace(/Bearer\s+[^\s"']+/gi, 'Bearer REDACTED')
    .replace(/[A-Za-z0-9_\-]{40,}/g, 'REDACTED')
    .replace(/[\r\n]+/g, ' ')
    .slice(0, maxLength);
}

/**
 * Pause or resume a credential through CLIProxyAPI.
 * @param {object} config Account Manager config (cliProxyApiUrl, cliProxyApiManagementKey)
 * @param {string} filename Exact credential filename from the account list
 * @param {boolean} disabled true = pause, false = resume
 */
export async function setAccountDisabled(config, filename, disabled) {
  if (!validateAuthFilename(filename)) {
    throw new ManagementError(
      ManagementErrorCode.INVALID_FILENAME,
      'Valid filename parameter is required.',
      400
    );
  }
  if (typeof disabled !== 'boolean') {
    throw new ManagementError(ManagementErrorCode.API_ERROR, 'Invalid target state.', 400);
  }

  const key = String(config.cliProxyApiManagementKey || '').trim();
  if (!key) {
    throw new ManagementError(
      ManagementErrorCode.KEY_MISSING,
      'CLIProxyAPI management key is not configured; pause/resume is unavailable.',
      503
    );
  }

  const url = `${String(config.cliProxyApiUrl || '').replace(/\/+$/, '')}/v8/management/credentials/status`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);

  try {
    const resp = await fetch(url, {
      method: 'PATCH',
      headers: {
        'Authorization': `Bearer ${key}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ name: filename, disabled }),
      signal: controller.signal
    });

    let payload = {};
    try {
      payload = await resp.json();
    } catch {
      // Some CLIProxyAPI versions answer with an empty body on success.
    }

    if (resp.status === 404) {
      throw new ManagementError(
        ManagementErrorCode.ACCOUNT_NOT_FOUND,
        `Account ${filename} was not found on CLIProxyAPI.`,
        404
      );
    }
    if (!resp.ok) {
      const detail = payload && payload.error ? `: ${sanitizeUpstreamText(payload.error)}` : '';
      throw new ManagementError(
        ManagementErrorCode.API_ERROR,
        `CLIProxyAPI rejected the status change (${resp.status})${detail}`,
        502
      );
    }

    return {
      success: true,
      filename,
      disabled,
      status: payload.status || 'ok'
    };
  } catch (err) {
    if (err instanceof ManagementError) throw err;
    if (err && err.name === 'AbortError') {
      throw new ManagementError(
        ManagementErrorCode.TIMEOUT,
        'CLIProxyAPI did not answer the status request in time.',
        504
      );
    }
    throw new ManagementError(
      ManagementErrorCode.UNAVAILABLE,
      `Unable to reach CLIProxyAPI: ${sanitizeUpstreamText(err && err.message)}`,
      502
    );
  } finally {
    clearTimeout(timer);
  }
}
