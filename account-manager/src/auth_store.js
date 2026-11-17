import fs from 'node:fs';
import path from 'node:path';

// Mask email addresses (e.g., coocaa.s3g@gmail.com -> coo***@gmail.com)
export function maskEmail(email) {
  if (!email || typeof email !== 'string') return '';
  const parts = email.split('@');
  if (parts.length !== 2) return email.slice(0, 3) + '***';
  const name = parts[0];
  const domain = parts[1];
  if (name.length <= 3) {
    return name[0] + '***@' + domain;
  }
  return name.slice(0, 3) + '***@' + domain;
}

// Error codes shared with the HTTP layer so failures can be reported clearly
// without ever including credential contents.
export const AccountStoreErrorCode = Object.freeze({
  INVALID_FILENAME: 'INVALID_FILENAME',
  NOT_FOUND: 'ACCOUNT_NOT_FOUND',
  NOT_CREDENTIAL: 'NOT_A_CREDENTIAL_FILE',
  DELETE_FAILED: 'DELETE_FAILED'
});

export class AccountStoreError extends Error {
  constructor(code, message, httpStatus = 400) {
    super(message);
    this.name = 'AccountStoreError';
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

// CLIProxyAPI auth filenames are `<provider>-<email>.json` for Codex/Claude/
// Antigravity (Gemini) and may include '@', '+' and dots in the email part.
// Allowed characters are deliberately restricted to a single safe path
// segment; anything else (slashes, traversal, control characters, shell
// metacharacters) is rejected before any filesystem access.
const AUTH_FILENAME_RE = /^[A-Za-z0-9@+._-]{3,249}\.json$/;

export function validateAuthFilename(filename) {
  if (!filename || typeof filename !== 'string') return false;
  if (!AUTH_FILENAME_RE.test(filename)) return false;
  if (filename.includes('..') || filename.startsWith('.')) return false;
  if (/[\u0000-\u001f\u007f]/.test(filename)) return false;
  return true;
}

// Known credential filename prefixes used by CLIProxyAPI providers. Kept as
// an additional guard; the authoritative check is the JSON shape below.
const CREDENTIAL_PREFIXES = [
  'codex-', 'xai-', 'antigravity-', 'gemini-', 'claude-',
  'grok-', 'vertex-', 'kimi-', 'devin-', 'meta-'
];

export class LocalAuthStore {
  constructor(authDir) {
    this.authDir = authDir;
  }

  // List all accounts from authDir
  listAccounts() {
    if (!fs.existsSync(this.authDir)) {
      return [];
    }

    const files = fs.readdirSync(this.authDir);
    const accounts = [];

    for (const file of files) {
      if (!file.endsWith('.json') || file.startsWith('.')) continue;
      const fullPath = path.join(this.authDir, file);

      try {
        const stat = fs.statSync(fullPath);
        if (!stat.isFile()) continue;

        const content = fs.readFileSync(fullPath, 'utf8');
        const data = JSON.parse(content);

        // Extract metadata safely, without leaking access_token or refresh_token
        const provider = (data.type || data.provider || this.guessProviderFromFilename(file)).toLowerCase();
        const rawEmail = data.email || (data.storage && data.storage.email) || '';
        const rawAccount = data.account || (data.storage && data.storage.account) || data.sub || (data.storage && data.storage.sub) || '';
        const planType = data.plan_type || (data.storage && data.storage.plan_type) || '';

        // Pause state is read from CLIProxyAPI's own `metadata.disabled` flag.
        // Missing flag means the account predates this feature and is active.
        // A non-boolean flag is reported, never treated as paused.
        const metadata = (data.metadata && typeof data.metadata === 'object') ? data.metadata : {};
        // CLIProxyAPI v8 writes the authoritative flag at the TOP LEVEL of the
        // auth file and may leave an older metadata.disabled value untouched.
        // Top-level therefore wins; metadata is only a fallback for legacy
        // files that predate CLIProxyAPI's native status field.
        const disabledValue = data.disabled !== undefined ? data.disabled : metadata.disabled;
        let state = 'active';
        let metadataError = null;
        if (disabledValue === true) {
          state = 'paused';
        } else if (disabledValue !== undefined && disabledValue !== false) {
          state = 'unknown';
          metadataError = 'invalid disabled flag in credential metadata';
        }

        // Status calculation
        let isExpired = false;
        let expiresAt = null;
        if (data.expired) {
          expiresAt = new Date(data.expired).toISOString();
          isExpired = new Date(data.expired).getTime() < Date.now();
        } else if (data.expires_in && data.last_refresh) {
          const expTime = new Date(data.last_refresh).getTime() + (data.expires_in * 1000);
          expiresAt = new Date(expTime).toISOString();
          isExpired = expTime < Date.now();
        }

        accounts.push({
          filename: file,
          provider,
          emailMasked: rawEmail ? maskEmail(rawEmail) : (rawAccount ? maskEmail(rawAccount) : 'unknown'),
          planType: planType || 'standard',
          // `status` keeps its original meaning (credential health) for
          // backward compatibility; `state` is the new Active/Paused flag.
          status: isExpired ? 'expired' : 'active',
          state,
          disabled: state === 'paused',
          ...(metadataError ? { metadataError } : {}),
          expiresAt,
          lastRefresh: data.last_refresh || stat.mtime.toISOString(),
          createdAt: stat.birthtime ? stat.birthtime.toISOString() : stat.mtime.toISOString(),
          sizeBytes: stat.size,
          // Explicitly confirm NO tokens are exposed
          hasRefreshToken: Boolean(data.refresh_token || (data.storage && data.storage.refresh_token))
        });
      } catch (err) {
        // Corrupted or invalid JSON file
        accounts.push({
          filename: file,
          provider: this.guessProviderFromFilename(file),
          emailMasked: 'error_reading',
          status: 'corrupted',
          state: 'unknown',
          disabled: false,
          error: err.message,
          sizeBytes: 0,
          hasRefreshToken: false
        });
      }
    }

    return accounts;
  }

  guessProviderFromFilename(filename) {
    const lower = filename.toLowerCase();
    if (lower.startsWith('codex')) return 'codex';
    if (lower.startsWith('xai') || lower.startsWith('grok')) return 'xai';
    if (lower.startsWith('antigravity') || lower.startsWith('gemini')) return 'gemini';
    if (lower.startsWith('claude')) return 'claude';
    return 'unknown';
  }

  // Get specific account safe metadata
  getAccount(filename) {
    if (!validateAuthFilename(filename)) {
      throw new AccountStoreError(
        AccountStoreErrorCode.INVALID_FILENAME,
        'Invalid filename format or potential directory traversal'
      );
    }
    const accounts = this.listAccounts();
    return accounts.find(a => a.filename === filename) || null;
  }

  // Resolve a filename to an absolute path that is guaranteed to be a direct
  // child of the configured auth directory. This is the single place that
  // turns an untrusted filename into a filesystem path.
  resolveAuthPath(filename) {
    if (!validateAuthFilename(filename)) {
      throw new AccountStoreError(
        AccountStoreErrorCode.INVALID_FILENAME,
        'Invalid filename format or potential directory traversal'
      );
    }
    const base = path.resolve(this.authDir);
    const fullPath = path.resolve(base, filename);
    if (path.dirname(fullPath) !== base) {
      throw new AccountStoreError(
        AccountStoreErrorCode.INVALID_FILENAME,
        'Invalid filename format or potential directory traversal'
      );
    }
    return fullPath;
  }

  // Validate that a resolved path is a real credential file, not a symlink or
  // an unrelated JSON document that happens to live in the auth directory.
  assertManagedCredential(fullPath, filename) {
    // Check the filename prefix before touching the filesystem. Unknown file
    // formats always get the same generic rejection (also avoids revealing
    // whether an unrelated file exists in the directory).
    if (!CREDENTIAL_PREFIXES.some(p => filename.toLowerCase().startsWith(p))) {
      throw new AccountStoreError(
        AccountStoreErrorCode.NOT_CREDENTIAL,
        `File ${filename} is not a recognized provider credential format`
      );
    }

    let stat;
    try {
      stat = fs.lstatSync(fullPath);
    } catch (err) {
      if (err.code === 'ENOENT') {
        throw new AccountStoreError(
          AccountStoreErrorCode.NOT_FOUND,
          `Account ${filename} was not found`,
          404
        );
      }
      throw new AccountStoreError(AccountStoreErrorCode.DELETE_FAILED, 'Unable to access account file', 500);
    }
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new AccountStoreError(
        AccountStoreErrorCode.NOT_CREDENTIAL,
        `File ${filename} is not a managed credential file`
      );
    }

    let data;
    try {
      data = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
    } catch {
      throw new AccountStoreError(
        AccountStoreErrorCode.NOT_CREDENTIAL,
        `File ${filename} is not a valid credential file`
      );
    }
    const values = Array.isArray(data) ? data : [data];
    const looksLikeCredential = values.length > 0 && values.every(item =>
      item && typeof item === 'object' && (
        item.type || item.provider || item.metadata || item.storage ||
        item.access_token || item.refresh_token
      )
    );
    if (!looksLikeCredential) {
      throw new AccountStoreError(
        AccountStoreErrorCode.NOT_CREDENTIAL,
        `File ${filename} is not a recognized provider credential format`
      );
    }
    return fullPath;
  }

  // Returns the validated absolute path for an account that may be deleted or
  // paused. Used by the HTTP layer before creating any backup.
  getManagedAccountPath(filename) {
    return this.assertManagedCredential(this.resolveAuthPath(filename), filename);
  }

  // Safely delete a specific account. Throws AccountStoreError with a stable
  // code so callers can distinguish a bad request from a missing account.
  deleteAccount(filename) {
    const fullPath = this.getManagedAccountPath(filename);
    try {
      fs.unlinkSync(fullPath);
    } catch (err) {
      throw new AccountStoreError(AccountStoreErrorCode.DELETE_FAILED, 'Unable to delete account file', 500);
    }
    return true;
  }

  // Backup authDir before any modification
  createBackup(backupDir) {
    if (!fs.existsSync(this.authDir)) return null;
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const targetDir = path.join(backupDir || path.dirname(this.authDir), `auths.bak.${timestamp}`);

    fs.mkdirSync(targetDir, { recursive: true });
    const files = fs.readdirSync(this.authDir);
    let count = 0;

    for (const file of files) {
      if (file.endsWith('.json')) {
        const src = path.join(this.authDir, file);
        const dst = path.join(targetDir, file);
        fs.copyFileSync(src, dst);
        count++;
      }
    }

    return { targetDir, count };
  }
}
