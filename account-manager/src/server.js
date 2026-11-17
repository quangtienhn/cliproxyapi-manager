import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.js';
import { hashPassword, verifyPassword, SessionManager, RateLimiter } from './auth.js';
import { AuditLogger } from './audit.js';
import { LocalAuthStore, AccountStoreError, AccountStoreErrorCode } from './auth_store.js';
import { setAccountDisabled, ManagementError, ManagementErrorCode } from './account_status.js';
import { createProviderRegistry } from './providers/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const PUBLIC_DIR = path.join(__dirname, '..', 'public');

export function createServer(customConfig = {}) {
  const config = { ...loadConfig(), ...customConfig };
  const sessionManager = new SessionManager(config.sessionTtlMinutes);
  const rateLimiter = new RateLimiter(config.rateLimitLoginMax, config.rateLimitLoginWindowSec);
  const auditLogger = new AuditLogger(config.auditLogPath);
  const authStore = new LocalAuthStore(config.authDir);
  const providerRegistry = createProviderRegistry(config);

  // Serialize pause/resume operations per server instance. CLIProxyAPI has its
  // own lock, but this prevents two local requests from racing and makes the
  // final metadata state deterministic.
  let statusChangeQueue = Promise.resolve();
  function serializeStatusChange(task) {
    const result = statusChangeQueue.then(task, task);
    statusChangeQueue = result.then(() => undefined, () => undefined);
    return result;
  }

  // Dedicated persistent admin config storage in dataDir
  const adminStateFile = path.join(config.dataDir, 'admin.json');

  let adminConfig = {
    username: config.adminUsername,
    passwordHash: config.adminPasswordHash
  };

  // Load persistent admin configuration if file exists
  if (fs.existsSync(adminStateFile)) {
    try {
      const persisted = JSON.parse(fs.readFileSync(adminStateFile, 'utf8'));
      if (persisted.username && persisted.passwordHash) {
        adminConfig.username = persisted.username;
        adminConfig.passwordHash = persisted.passwordHash;
      }
    } catch (err) {
      console.error(`[WARN] Failed to read admin state file ${adminStateFile}:`, err.message);
    }
  }

  // Helper: Parse cookies
  function parseCookies(req) {
    const list = {};
    const rc = req.headers.cookie;
    if (rc) {
      rc.split(';').forEach(cookie => {
        const parts = cookie.split('=');
        list[parts.shift().trim()] = decodeURI(parts.join('='));
      });
    }
    return list;
  }

  // Helper: Read JSON body
  async function readJsonBody(req) {
    return new Promise((resolve, reject) => {
      let body = '';
      req.on('data', chunk => {
        body += chunk;
        if (body.length > 1024 * 1024) { // 1MB limit
          reject(new Error('Request body too large'));
        }
      });
      req.on('end', () => {
        if (!body.trim()) return resolve({});
        try {
          resolve(JSON.parse(body));
        } catch (err) {
          reject(new Error('Invalid JSON'));
        }
      });
      req.on('error', reject);
    });
  }

  // Helper: Send JSON response
  function sendJson(res, statusCode, data, headers = {}) {
    const body = JSON.stringify(data);
    res.writeHead(statusCode, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Cache-Control': 'no-store',
      ...headers
    });
    res.end(body);
  }

  // Helper: map a typed error to an HTTP status. Messages are already safe to
  // display (no credential values are ever included).
  function errorHttpStatus(err, fallback) {
    if (err instanceof AccountStoreError || err instanceof ManagementError) {
      return err.httpStatus || fallback;
    }
    return fallback;
  }

  // Helper: Send Static file
  function sendFile(res, filePath, contentType) {
    fs.readFile(filePath, (err, content) => {
      if (err) {
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not Found');
        return;
      }
      res.writeHead(200, {
        'Content-Type': contentType,
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY'
      });
      res.end(content);
    });
  }

  // Helper: Authenticate session
  function getAuthenticatedSession(req) {
    const cookies = parseCookies(req);
    const sessionToken = cookies['am_session'];
    if (!sessionToken) return null;
    return sessionManager.getSession(sessionToken);
  }

  const server = http.createServer(async (req, res) => {
    const clientIp = req.socket.remoteAddress || '127.0.0.1';
    const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = parsedUrl.pathname;
    const method = req.method;

    // 1. Static Assets
    if (method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
      return sendFile(res, path.join(PUBLIC_DIR, 'index.html'), 'text/html; charset=utf-8');
    }
    if (method === 'GET' && pathname === '/app.js') {
      return sendFile(res, path.join(PUBLIC_DIR, 'app.js'), 'application/javascript; charset=utf-8');
    }
    if (method === 'GET' && pathname === '/style.css') {
      return sendFile(res, path.join(PUBLIC_DIR, 'style.css'), 'text/css; charset=utf-8');
    }

    // 2. Health check
    if (method === 'GET' && pathname === '/api/health') {
      return sendJson(res, 200, {
        status: 'healthy',
        service: 'cliproxyapi-account-manager',
        timestamp: new Date().toISOString()
      });
    }

    // 3. System setup status check (requires setup if password hash not configured)
    if (method === 'GET' && pathname === '/api/status') {
      const session = getAuthenticatedSession(req);
      const requiresSetup = !adminConfig.passwordHash;
      return sendJson(res, 200, {
        requiresSetup,
        authenticated: Boolean(session),
        username: session ? session.username : null,
        csrfToken: session ? session.csrfToken : null
      });
    }

    // 4. Initial Setup (First-time password creation)
    if (method === 'POST' && pathname === '/api/setup') {
      // Check current in-memory or persisted admin state
      if (adminConfig.passwordHash || fs.existsSync(adminStateFile)) {
        return sendJson(res, 400, { error: 'Administrator account is already initialized.' });
      }

      try {
        const body = await readJsonBody(req);
        const { username, password } = body;
        if (!password || password.length < 8) {
          return sendJson(res, 400, { error: 'Password must be at least 8 characters.' });
        }

        const hashed = await hashPassword(password);
        const adminUser = (username || 'admin').trim();

        // Atomic write to dataDir/admin.json using exclusive flag ('wx') to prevent race conditions
        fs.mkdirSync(config.dataDir, { recursive: true });
        const tempState = {
          username: adminUser,
          passwordHash: hashed,
          createdAt: new Date().toISOString()
        };

        const tempFile = path.join(config.dataDir, `.admin.tmp.${Date.now()}`);
        fs.writeFileSync(tempFile, JSON.stringify(tempState, null, 2), { mode: 0o600 });
        
        try {
          // atomic rename; if file already exists in case of concurrent requests, fail safe
          if (fs.existsSync(adminStateFile)) {
            fs.unlinkSync(tempFile);
            return sendJson(res, 400, { error: 'Administrator account is already initialized.' });
          }
          fs.renameSync(tempFile, adminStateFile);
        } catch (renameErr) {
          try { fs.unlinkSync(tempFile); } catch {}
          throw renameErr;
        }

        adminConfig.username = adminUser;
        adminConfig.passwordHash = hashed;

        auditLogger.log('ADMIN_INITIALIZED', { username: adminConfig.username }, clientIp, adminConfig.username);
        return sendJson(res, 200, { success: true, message: 'Admin setup completed successfully.' });
      } catch (err) {
        return sendJson(res, 400, { error: err.message });
      }
    }

    // 5. Login
    if (method === 'POST' && pathname === '/api/login') {
      if (!rateLimiter.isAllowed(clientIp)) {
        auditLogger.log('LOGIN_RATE_LIMITED', {}, clientIp, 'unknown');
        return sendJson(res, 429, { error: 'Too many failed login attempts. Please try again later.' });
      }

      try {
        const body = await readJsonBody(req);
        const { username, password } = body;

        if (!adminConfig.passwordHash) {
          return sendJson(res, 400, { error: 'Admin setup required.' });
        }

        const isValid = username === adminConfig.username && await verifyPassword(password, adminConfig.passwordHash);

        if (!isValid) {
          rateLimiter.recordAttempt(clientIp, false);
          auditLogger.log('LOGIN_FAILED', { username }, clientIp, username || 'unknown');
          return sendJson(res, 401, { error: 'Invalid username or password.' });
        }

        rateLimiter.recordAttempt(clientIp, true);
        const { sessionToken, csrfToken, expiresAt } = sessionManager.createSession(username);

        const secureFlag = config.cookieSecure ? '; Secure' : '';
        const cookie = `am_session=${sessionToken}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${config.sessionTtlMinutes * 60}${secureFlag}`;

        auditLogger.log('LOGIN_SUCCESS', { username }, clientIp, username);

        return sendJson(res, 200, {
          success: true,
          username,
          csrfToken,
          expiresAt
        }, { 'Set-Cookie': cookie });
      } catch (err) {
        return sendJson(res, 400, { error: err.message });
      }
    }

    // 6. Logout
    if (method === 'POST' && pathname === '/api/logout') {
      const cookies = parseCookies(req);
      const sessionToken = cookies['am_session'];
      sessionManager.destroySession(sessionToken);
      const cookie = `am_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0`;
      auditLogger.log('LOGOUT', {}, clientIp, 'user');
      return sendJson(res, 200, { success: true }, { 'Set-Cookie': cookie });
    }

    // --- PROTECTED ROUTES BELOW ---
    const session = getAuthenticatedSession(req);
    if (!session) {
      return sendJson(res, 401, { error: 'Unauthorized. Please login.' });
    }

    // CSRF verification for state-modifying requests
    if (['POST', 'PUT', 'DELETE', 'PATCH'].includes(method)) {
      const clientCsrf = req.headers['x-csrf-token'];
      if (!sessionManager.validateCsrf(parseCookies(req)['am_session'], clientCsrf)) {
        auditLogger.log('CSRF_VIOLATION', { path: pathname, method }, clientIp, session.username);
        return sendJson(res, 403, { error: 'Invalid or missing CSRF token.' });
      }
    }

    // 7. Get Providers
    if (method === 'GET' && pathname === '/api/providers') {
      return sendJson(res, 200, { providers: providerRegistry.list() });
    }

    // 8. List Accounts
    if (method === 'GET' && pathname === '/api/accounts') {
      const accounts = authStore.listAccounts();
      const usable = accounts.filter(a => a.state === 'active' && a.status === 'active');
      return sendJson(res, 200, {
        total: accounts.length,
        // Backward-compatible fields plus explicit state counters.
        active: usable.length,
        paused: accounts.filter(a => a.state === 'paused').length,
        accounts
      });
    }

    // 9. Delete Account
    if (method === 'DELETE' && pathname === '/api/accounts') {
      const filename = parsedUrl.searchParams.get('filename');
      if (!filename) {
        return sendJson(res, 400, { error: 'Valid filename parameter is required.' });
      }

      try {
        // Validate and confirm the file exists BEFORE making a backup, so a
        // bad request or a missing account never creates a useless backup.
        authStore.getManagedAccountPath(filename);
        authStore.createBackup();
        authStore.deleteAccount(filename);
        auditLogger.log('ACCOUNT_DELETED', { filename }, clientIp, session.username);
        return sendJson(res, 200, { success: true, message: `Account ${filename} removed successfully.` });
      } catch (err) {
        const status = errorHttpStatus(err, 500);
        if (status >= 500) {
          console.error('[ERROR] Account deletion failed:', err && err.message);
        }
        return sendJson(res, status, { error: err.message || 'Unable to delete account.' });
      }
    }

    // 9a. Pause / Resume Account
    // The browser sends the exact auth filename; CLIProxyAPI's native
    // disabled flag is toggled through its Management API. No auth file is
    // renamed, moved, or rewritten by Account Manager itself.
    if ((method === 'POST') && (pathname === '/api/accounts/pause' || pathname === '/api/accounts/resume')) {
      const targetState = pathname.endsWith('/pause') ? 'paused' : 'active';
      const disabled = targetState === 'paused';
      const filename = parsedUrl.searchParams.get('filename');
      if (!filename) {
        return sendJson(res, 400, { error: 'Valid filename parameter is required.' });
      }

      try {
        const result = await serializeStatusChange(async () => {
          authStore.getManagedAccountPath(filename);
          const account = authStore.getAccount(filename);
          if (!account) {
            throw new AccountStoreError(
              AccountStoreErrorCode.NOT_FOUND,
              `Account ${filename} was not found`,
              404
            );
          }
          if (disabled && account.state === 'paused') {
            throw new ManagementError(ManagementErrorCode.ALREADY_PAUSED, 'Account is already paused.', 409);
          }
          if (!disabled && account.state === 'active') {
            throw new ManagementError(ManagementErrorCode.NOT_PAUSED, 'Account is not paused.', 409);
          }
          const outcome = await setAccountDisabled(config, filename, disabled);
          // Re-read from disk so the caller sees the persisted state, and so a
          // silent CLIProxyAPI failure cannot leave the UI out of sync.
          const after = authStore.getAccount(filename);
          if (!after || after.state !== targetState) {
            throw new ManagementError(
              ManagementErrorCode.VERIFY_FAILED,
              'CLIProxyAPI accepted the request but the persisted state did not change.',
              502
            );
          }
          return { outcome, after };
        });

        auditLogger.log(disabled ? 'ACCOUNT_PAUSED' : 'ACCOUNT_RESUMED', { filename }, clientIp, session.username);
        return sendJson(res, 200, {
          success: true,
          filename,
          state: result.after.state,
          message: disabled
            ? `Account ${filename} paused. CLIProxyAPI will not use it for new requests.`
            : `Account ${filename} resumed.`
        });
      } catch (err) {
        const status = errorHttpStatus(err, 502);
        if (status >= 500) {
          console.error('[ERROR] Account status change failed:', err && err.message);
        }
        return sendJson(res, status, { error: err.message || 'Unable to change account state.' });
      }
    }

    // 10. Start OAuth
    if (method === 'POST' && pathname === '/api/oauth/init') {
      try {
        const body = await readJsonBody(req);
        const { provider: providerType } = body;
        const adapter = providerRegistry.get(providerType);
        if (!adapter) {
          return sendJson(res, 404, { error: `Provider ${providerType} not found.` });
        }

        auditLogger.log('OAUTH_INITIATE', { provider: providerType }, clientIp, session.username);
        const result = await adapter.initiateOAuth();
        return sendJson(res, result.success ? 200 : 400, result);
      } catch (err) {
        return sendJson(res, 500, { error: err.message });
      }
    }

    // 11. Poll OAuth Status
    if (method === 'GET' && pathname === '/api/oauth/status') {
      const state = parsedUrl.searchParams.get('state');
      const providerType = parsedUrl.searchParams.get('provider');
      if (!state || !providerType) {
        return sendJson(res, 400, { error: 'Missing state or provider parameter.' });
      }

      const adapter = providerRegistry.get(providerType);
      if (!adapter) {
        return sendJson(res, 404, { error: `Provider ${providerType} not found.` });
      }

      const status = await adapter.checkOAuthStatus(state);
      if (status.status === 'ok') {
        auditLogger.log('OAUTH_COMPLETED', { provider: providerType, state }, clientIp, session.username);
      }
      return sendJson(res, 200, status);
    }

    // 12. Cancel OAuth Session
    if (method === 'DELETE' && pathname === '/api/oauth/session') {
      const state = parsedUrl.searchParams.get('state');
      const providerType = parsedUrl.searchParams.get('provider');
      if (!state || !providerType) {
        return sendJson(res, 400, { error: 'Missing state or provider parameter.' });
      }

      const adapter = providerRegistry.get(providerType);
      if (adapter) {
        await adapter.cancelOAuth(state);
      }
      auditLogger.log('OAUTH_CANCELLED', { provider: providerType, state }, clientIp, session.username);
      return sendJson(res, 200, { success: true });
    }

    // 13. List Models
    if (method === 'GET' && pathname === '/api/models') {
      const providerType = parsedUrl.searchParams.get('provider');
      if (providerType) {
        const adapter = providerRegistry.get(providerType);
        if (!adapter) {
          return sendJson(res, 404, { error: 'Provider not found' });
        }
        const models = await adapter.getModels(config.cliProxyApiUrl);
        return sendJson(res, 200, { models });
      }

      // Fetch all models
      try {
        const resp = await fetch(`${config.cliProxyApiUrl}/v1/models`);
        if (!resp.ok) {
          return sendJson(res, 200, { models: [] });
        }
        const data = await resp.json();
        return sendJson(res, 200, { models: data.data || data.models || [] });
      } catch (err) {
        return sendJson(res, 200, { models: [], error: err.message });
      }
    }

    // 14. Test Connection / Inference
    if (method === 'POST' && pathname === '/api/test-connection') {
      try {
        const body = await readJsonBody(req);
        const { provider: providerType, model } = body;
        const adapter = providerRegistry.get(providerType);
        if (!adapter) {
          return sendJson(res, 404, { error: `Provider ${providerType} not found.` });
        }

        auditLogger.log('TEST_CONNECTION', { provider: providerType, model }, clientIp, session.username);
        const testResult = await adapter.testConnection(config.cliProxyApiUrl, model);
        return sendJson(res, 200, testResult);
      } catch (err) {
        return sendJson(res, 500, { error: err.message });
      }
    }

    // Default 404
    return sendJson(res, 404, { error: 'Not Found' });
  });

  return { server, config, sessionManager, auditLogger, authStore, adminConfig };
}

// Start standalone if executed directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { server, config } = createServer();
  server.listen(config.port, config.host, () => {
    console.log(`====================================================`);
    console.log(` CLIProxyAPI Account Manager v1.0.0`);
    console.log(` Listening on: http://${config.host}:${config.port}`);
    console.log(` CLIProxyAPI Target: ${config.cliProxyApiUrl}`);
    console.log(` Auth Dir: ${config.authDir}`);
    console.log(`====================================================`);
  });
}
