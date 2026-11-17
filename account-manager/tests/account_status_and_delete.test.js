import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';

import { createServer } from '../src/server.js';
import { LocalAuthStore } from '../src/auth_store.js';
import { createMockCLIProxyAPI } from './mock_cliproxyapi.js';

// All data in this suite is synthetic and created in a temporary directory.
// No production auth file, token, or credential is read, written, or deleted.

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

const GEMINI = 'antigravity-synthetic.user@example.com.json';
const CODEX = 'codex-synthetic.dev@example.com.json';
const XAI = 'xai-synthetic.grok@example.com.json';
const LEGACY = 'claude-legacy@example.com.json';
const FAILING = 'xai-failing@example.com.json';

function credential(type, email, extra = {}) {
  return {
    type,
    email,
    plan_type: 'synthetic',
    access_token: `synthetic_access_${type}`,
    refresh_token: `synthetic_refresh_${type}`,
    last_refresh: new Date().toISOString(),
    ...extra
  };
}

async function bootstrap(options = {}) {
  const { includeLegacy = false, includeFailing = false, managementKey = 'synthetic-management-key' } = options;
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'am-pause-delete-'));
  const authDir = path.join(tempDir, 'auths');
  fs.mkdirSync(authDir, { recursive: true });

  const fixtures = [
    { file: GEMINI, data: credential('antigravity', 'synthetic.user@example.com', { metadata: {} }) },
    { file: CODEX, data: credential('codex', 'synthetic.dev@example.com', { metadata: {} }) },
    { file: XAI, data: credential('xai', 'synthetic.grok@example.com', { metadata: {} }) }
  ];
  if (includeLegacy) {
    // No metadata at all: must default to Active.
    fixtures.push({ file: LEGACY, data: credential('claude', 'synthetic.legacy@example.com') });
  }
  if (includeFailing) {
    fixtures.push({
      file: FAILING,
      data: credential('xai', 'synthetic.failing@example.com', { metadata: { disabled: true } })
    });
  }
  for (const f of fixtures) {
    fs.writeFileSync(path.join(authDir, f.file), JSON.stringify(f.data), { mode: 0o600 });
  }

  const mock = createMockCLIProxyAPI(await freePort(), fixtures.map(f => ({
    id: f.file,
    provider: f.data.type,
    email: f.data.email,
    storage: { access_token: f.data.access_token, refresh_token: f.data.refresh_token }
  })), authDir);
  await mock.listen();

  const port = await freePort();
  const { server } = createServer({
    port,
    host: '127.0.0.1',
    cliProxyApiUrl: mock.url,
    cliProxyApiManagementKey: managementKey,
    authDir,
    dataDir: path.join(tempDir, 'data'),
    auditLogPath: path.join(tempDir, 'audit.log'),
    adminUsername: 'admin',
    adminPasswordHash: ''
  });
  await new Promise(resolve => server.listen(port, '127.0.0.1', resolve));

  const baseUrl = `http://127.0.0.1:${port}`;
  const setup = await fetch(`${baseUrl}/api/setup`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: 'SyntheticPassword123!' })
  });
  assert.equal(setup.status, 200);
  const login = await fetch(`${baseUrl}/api/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: 'SyntheticPassword123!' })
  });
  const loginData = await login.json();
  const sessionCookie = login.headers.get('set-cookie').split(';')[0];

  function request(target, { method = 'GET', csrf = false, body } = {}) {
    const headers = { Cookie: sessionCookie };
    if (csrf) headers['x-csrf-token'] = loginData.csrfToken;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    return fetch(baseUrl + target, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined
    });
  }

  return {
    tempDir,
    authDir,
    baseUrl,
    mock,
    store: new LocalAuthStore(authDir),
    request,
    readRaw(file) {
      return JSON.parse(fs.readFileSync(path.join(authDir, file), 'utf8'));
    },
    fileExists(file) {
      return fs.existsSync(path.join(authDir, file));
    },
    async close() {
      await new Promise(resolve => server.close(resolve));
      await mock.close();
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  };
}

function withoutStateFlags(raw) {
  const copy = JSON.parse(JSON.stringify(raw));
  delete copy.metadata;
  delete copy.disabled;
  return copy;
}

// ---------------------------------------------------------------------------
// Delete tests
// ---------------------------------------------------------------------------

test('DELETE: Gemini/Antigravity account with email filename is deleted', async () => {
  const ctx = await bootstrap();
  try {
    const res = await ctx.request(`/api/accounts?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'DELETE',
      csrf: true
    });
    assert.equal(res.status, 200, (await res.text()));
    assert.equal(ctx.fileExists(GEMINI), false);
    assert.equal(ctx.fileExists(CODEX), true);
    assert.equal(ctx.fileExists(XAI), true);
    const listed = ctx.store.listAccounts().map(a => a.filename).sort();
    assert.deepEqual(listed, [CODEX, XAI].sort());
  } finally {
    await ctx.close();
  }
});

test('DELETE: other providers (Codex, xAI) remain supported', async () => {
  const ctx = await bootstrap();
  try {
    for (const file of [CODEX, XAI]) {
      const res = await ctx.request(`/api/accounts?filename=${encodeURIComponent(file)}`, {
        method: 'DELETE',
        csrf: true
      });
      assert.equal(res.status, 200);
      assert.equal(ctx.fileExists(file), false);
    }
    assert.equal(ctx.fileExists(GEMINI), true);
  } finally {
    await ctx.close();
  }
});

test('DELETE: missing filename is rejected with 400', async () => {
  const ctx = await bootstrap();
  try {
    const res = await ctx.request('/api/accounts', { method: 'DELETE', csrf: true });
    assert.equal(res.status, 400);
    const body = await res.json();
    assert.match(body.error, /filename/i);
    assert.equal(ctx.store.listAccounts().length, 3);
  } finally {
    await ctx.close();
  }
});

test('DELETE: invalid filenames are rejected without touching the filesystem', async () => {
  const ctx = await bootstrap();
  try {
    const badNames = ['../etc/passwd', 'codex.json; rm -rf /', 'bad.txt', 'codex\\user.json', '..hidden.json'];
    for (const name of badNames) {
      const res = await ctx.request(`/api/accounts?filename=${encodeURIComponent(name)}`, {
        method: 'DELETE',
        csrf: true
      });
      assert.equal(res.status, 400, `expected 400 for ${name}`);
    }
    assert.equal(ctx.store.listAccounts().length, 3);
  } finally {
    await ctx.close();
  }
});

test('DELETE: non-existent account returns 404 and a backup is not created', async () => {
  const ctx = await bootstrap();
  try {
    const before = fs.readdirSync(ctx.authDir).length;
    const res = await ctx.request(`/api/accounts?filename=${encodeURIComponent('codex-missing@example.com.json')}`, {
      method: 'DELETE',
      csrf: true
    });
    assert.equal(res.status, 404);
    assert.equal(fs.readdirSync(ctx.authDir).length, before);
  } finally {
    await ctx.close();
  }
});

test('DELETE: path traversal cannot remove a file outside the auth directory', async () => {
  const ctx = await bootstrap();
  try {
    const outside = path.join(ctx.tempDir, 'outside.json');
    fs.writeFileSync(outside, JSON.stringify(credential('codex', 'outside@example.com')));
    const res = await ctx.request(`/api/accounts?filename=${encodeURIComponent('../outside.json')}`, {
      method: 'DELETE',
      csrf: true
    });
    assert.equal(res.status, 400);
    assert.equal(fs.existsSync(outside), true);
  } finally {
    await ctx.close();
  }
});

test('DELETE: a paused account can still be deleted', async () => {
  const ctx = await bootstrap();
  try {
    const pause = await ctx.request(`/api/accounts/pause?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'POST',
      csrf: true
    });
    assert.equal(pause.status, 200);
    assert.equal(ctx.readRaw(GEMINI).metadata.disabled, true);

    const del = await ctx.request(`/api/accounts?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'DELETE',
      csrf: true
    });
    assert.equal(del.status, 200);
    assert.equal(ctx.fileExists(GEMINI), false);
    assert.equal(ctx.fileExists(CODEX), true);
  } finally {
    await ctx.close();
  }
});

// ---------------------------------------------------------------------------
// Pause / Resume tests
// ---------------------------------------------------------------------------

test('PAUSE: Active -> Paused persists disabled=true and preserves credentials', async () => {
  const ctx = await bootstrap();
  try {
    const before = ctx.readRaw(GEMINI);
    const res = await ctx.request(`/api/accounts/pause?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'POST',
      csrf: true
    });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(body.state, 'paused');
    assert.equal(ctx.fileExists(GEMINI), true);
    const after = ctx.readRaw(GEMINI);
    assert.equal(after.metadata.disabled, true);
    assert.deepEqual(withoutStateFlags(after), withoutStateFlags(before));
    assert.equal(ctx.mock.isDisabled(GEMINI), true);
  } finally {
    await ctx.close();
  }
});

test('RESUME: Paused -> Active clears disabled and preserves credentials', async () => {
  const ctx = await bootstrap();
  try {
    const paused = ctx.readRaw(GEMINI);
    paused.metadata = { disabled: true };
    fs.writeFileSync(path.join(ctx.authDir, GEMINI), JSON.stringify(paused));
    const before = JSON.parse(JSON.stringify(paused));

    const res = await ctx.request(`/api/accounts/resume?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'POST',
      csrf: true
    });
    const body = await res.json();
    assert.equal(res.status, 200);
    assert.equal(body.state, 'active');
    const after = ctx.readRaw(GEMINI);
    assert.equal(after.metadata.disabled, false);
    assert.deepEqual(withoutStateFlags(after), withoutStateFlags(before));
    assert.equal(ctx.mock.isDisabled(GEMINI), false);
  } finally {
    await ctx.close();
  }
});

test('PAUSE/RESUME: non-existent accounts return 404', async () => {
  const ctx = await bootstrap();
  try {
    const missing = encodeURIComponent('codex-not-there@example.com.json');
    const pause = await ctx.request(`/api/accounts/pause?filename=${missing}`, { method: 'POST', csrf: true });
    const resume = await ctx.request(`/api/accounts/resume?filename=${missing}`, { method: 'POST', csrf: true });
    assert.equal(pause.status, 404);
    assert.equal(resume.status, 404);
  } finally {
    await ctx.close();
  }
});

test('PAUSE: state survives a restart (new store instance reads same auth dir)', async () => {
  const ctx = await bootstrap();
  try {
    const res = await ctx.request(`/api/accounts/pause?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'POST',
      csrf: true
    });
    assert.equal(res.status, 200);
    const restartedStore = new LocalAuthStore(ctx.authDir);
    const account = restartedStore.getAccount(GEMINI);
    assert.equal(account.state, 'paused');
    assert.equal(account.disabled, true);
    const listed = restartedStore.listAccounts();
    assert.equal(listed.filter(a => a.state === 'paused').length, 1);
  } finally {
    await ctx.close();
  }
});

test('LEGACY: account without metadata metadata defaults to Active', async () => {
  const ctx = await bootstrap({ includeLegacy: true });
  try {
    const account = ctx.store.getAccount(LEGACY);
    assert.equal(account.state, 'active');
    assert.equal(account.disabled, false);
    assert.equal(account.metadataError, undefined);
  } finally {
    await ctx.close();
  }
});

test('STATE: CLIProxyAPI top-level disabled overrides stale metadata.disabled', async () => {
  const ctx = await bootstrap();
  try {
    // This mirrors real CLIProxyAPI v8 behaviour: it writes a top-level flag
    // and leaves the older metadata.disabled value untouched.
    const raw = ctx.readRaw(GEMINI);
    raw.disabled = false;
    raw.metadata = { disabled: true };
    fs.writeFileSync(path.join(ctx.authDir, GEMINI), JSON.stringify(raw));
    assert.equal(ctx.store.getAccount(GEMINI).state, 'active');

    raw.disabled = true;
    raw.metadata = { disabled: false };
    fs.writeFileSync(path.join(ctx.authDir, GEMINI), JSON.stringify(raw));
    assert.equal(ctx.store.getAccount(GEMINI).state, 'paused');
  } finally {
    await ctx.close();
  }
});

test('METADATA: invalid disabled flag is reported, never treated as paused', async () => {
  const ctx = await bootstrap();
  try {
    const raw = ctx.readRaw(GEMINI);
    raw.metadata = { disabled: 'yes' };
    fs.writeFileSync(path.join(ctx.authDir, GEMINI), JSON.stringify(raw));
    const account = ctx.store.getAccount(GEMINI);
    assert.equal(account.state, 'unknown');
    assert.match(account.metadataError, /disabled/i);
  } finally {
    await ctx.close();
  }
});

test('PAUSE: paused account is not selected for new requests; other active accounts still are', async () => {
  const ctx = await bootstrap();
  try {
    const pause = await ctx.request(`/api/accounts/pause?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'POST',
      csrf: true
    });
    assert.equal(pause.status, 200);

    // Ask the simulated CLIProxyAPI gateway which credential it would use for
    // a new request. This is the authoritative selection behaviour.
    const test = await fetch(`${ctx.mock.url}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'gpt-4o-mini', messages: [{ role: 'user', content: 'Ping' }] })
    });
    const body = await test.json();
    assert.equal(test.status, 200);
    assert.equal(body.selected, CODEX, 'a paused credential must not be selected');
    assert.notEqual(body.selected, GEMINI);
  } finally {
    await ctx.close();
  }
});

test('PAUSE: dashboard counters exclude paused accounts', async () => {
  const ctx = await bootstrap();
  try {
    const before = await (await ctx.request('/api/accounts')).json();
    assert.equal(before.active, 3);
    assert.equal(before.paused, 0);
    const pause = await ctx.request(`/api/accounts/pause?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'POST',
      csrf: true
    });
    assert.equal(pause.status, 200);
    const after = await (await ctx.request('/api/accounts')).json();
    assert.equal(after.active, 2);
    assert.equal(after.paused, 1);
    assert.equal(after.total, 3);
  } finally {
    await ctx.close();
  }
});

test('RESUME: management API failure leaves the credential and state unchanged', async () => {
  const ctx = await bootstrap({ includeFailing: true });
  try {
    const before = ctx.readRaw(FAILING);
    const res = await ctx.request(`/api/accounts/resume?filename=${encodeURIComponent(FAILING)}`, {
      method: 'POST',
      csrf: true
    });
    assert.equal(res.status, 502);
    assert.deepEqual(ctx.readRaw(FAILING), before);
    assert.equal(ctx.fileExists(FAILING), true);
    assert.equal(ctx.store.getAccount(FAILING).state, 'paused');
  } finally {
    await ctx.close();
  }
});

test('PAUSE: missing management key fails closed with 503', async () => {
  const ctx = await bootstrap({ managementKey: '' });
  try {
    const res = await ctx.request(`/api/accounts/pause?filename=${encodeURIComponent(GEMINI)}`, {
      method: 'POST',
      csrf: true
    });
    assert.equal(res.status, 503);
    assert.equal(ctx.readRaw(GEMINI).metadata.disabled, undefined);
    assert.equal(ctx.store.getAccount(GEMINI).state, 'active');
  } finally {
    await ctx.close();
  }
});

test('CONCURRENCY: simultaneous pause/resume cannot corrupt metadata', async () => {
  const ctx = await bootstrap();
  try {
    const results = await Promise.all([
      ctx.request(`/api/accounts/pause?filename=${encodeURIComponent(GEMINI)}`, { method: 'POST', csrf: true }),
      ctx.request(`/api/accounts/resume?filename=${encodeURIComponent(GEMINI)}`, { method: 'POST', csrf: true })
    ]);
    const statuses = results.map(r => r.status).sort();
    assert.ok(statuses.every(s => s === 200 || s === 409), `unexpected statuses: ${statuses}`);
    const raw = ctx.readRaw(GEMINI);
    assert.equal(typeof raw.metadata.disabled, 'boolean');
    assert.equal(ctx.mock.isDisabled(GEMINI), raw.metadata.disabled);
    assert.equal(ctx.store.getAccount(GEMINI).state, raw.metadata.disabled ? 'paused' : 'active');
  } finally {
    await ctx.close();
  }
});

test('REGRESSION: list, details and test-connection endpoints remain compatible', async () => {
  const ctx = await bootstrap();
  try {
    const listed = await (await ctx.request('/api/accounts')).json();
    assert.equal(listed.total, 3);
    assert.equal(listed.accounts[0].access_token, undefined);
    assert.equal(listed.accounts[0].refresh_token, undefined);
    assert.ok(listed.accounts.some(a => a.filename === GEMINI && a.emailMasked.includes('***')));

    const details = ctx.store.getAccount(GEMINI);
    assert.equal(details.filename, GEMINI);
    assert.equal(details.hasRefreshToken, true);

    const test = await ctx.request('/api/test-connection', {
      method: 'POST',
      csrf: true,
      body: { provider: 'codex', model: 'gpt-4o-mini' }
    });
    assert.equal(test.status, 200);
    assert.equal((await test.json()).success, true);
  } finally {
    await ctx.close();
  }
});
