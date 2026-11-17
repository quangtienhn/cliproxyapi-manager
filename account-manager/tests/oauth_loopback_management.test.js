import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { CodexAdapter } from '../src/providers/codex.js';
import { XAIAdapter } from '../src/providers/xai.js';

test('OAuth Loopback Management Security: Headers, Redaction, and Error Handling', async () => {
  const SECRET_KEY = 'super-secret-loopback-management-key-999';
  let lastAuthHeader = '';
  let managementAvailable = false;

  // Mock server simulating CLIProxyAPI v8.0.61 loopback management
  const mockServer = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    lastAuthHeader = req.headers['authorization'] || '';

    // If management disabled, return 404
    if (!managementAvailable) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: '404 page not found' }));
    }

    // Require Bearer secret
    if (lastAuthHeader !== `Bearer ${SECRET_KEY}`) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'unauthorized' }));
    }

    // Codex Auth URL
    if (url.pathname === '/v8/management/oauth/auth-url' && url.searchParams.get('provider') === 'codex') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({
        status: 'ok',
        state: 'codex-state-123',
        url: 'https://auth.openai.com/oauth/authorize?state=codex-state-123'
      }));
    }

    // xAI Auth URL
    if (url.pathname === '/v8/management/oauth/auth-url' && url.searchParams.get('provider') === 'xai') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({
        status: 'ok',
        flow: 'device',
        state: 'xai-state-456',
        url: 'https://auth.x.ai/activate',
        user_code: 'XAI-8888',
        expires_in: 1800
      }));
    }

    // Status polling
    if (url.pathname === '/v8/management/oauth/status') {
      const state = url.searchParams.get('state');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({
        status: 'wait',
        state,
        saved: false
      }));
    }

    // Session cancellation
    if (url.pathname === '/v8/management/oauth/session' && req.method === 'DELETE') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ status: 'ok' }));
    }

    res.writeHead(404);
    res.end();
  });

  await new Promise(resolve => mockServer.listen(8499, '127.0.0.1', resolve));
  const serverUrl = 'http://127.0.0.1:8499';

  try {
    // 1. Test when Management API is DISABLED (default state on TX3)
    const codexDisabled = new CodexAdapter({ cliProxyApiUrl: serverUrl, managementKey: '' });
    const resDisabled = await codexDisabled.initiateOAuth();
    assert.equal(resDisabled.success, false);
    assert.ok(resDisabled.error.includes('404'), 'Should report 404 when management is disabled');

    // 2. Enable Management on Loopback
    managementAvailable = true;

    // 3. Test Codex Initiation with Management Key
    const codex = new CodexAdapter({ cliProxyApiUrl: serverUrl, managementKey: SECRET_KEY });
    const resCodex = await codex.initiateOAuth();
    assert.equal(resCodex.success, true);
    assert.equal(resCodex.flow, 'browser_redirect');
    assert.equal(resCodex.state, 'codex-state-123');
    assert.ok(resCodex.authUrl.includes('https://auth.openai.com'));
    assert.equal(lastAuthHeader, `Bearer ${SECRET_KEY}`);

    // Verify Secret is NOT in returned payload
    assert.equal(JSON.stringify(resCodex).includes(SECRET_KEY), false, 'Secret key must not leak to caller');

    // Poll status
    const statusCodex = await codex.checkOAuthStatus(resCodex.state);
    assert.equal(statusCodex.status, 'wait');

    // Cancel session
    const cancelCodex = await codex.cancelOAuth(resCodex.state);
    assert.equal(cancelCodex, true);

    // 4. Test xAI Device Code Flow with Management Key
    const xai = new XAIAdapter({ cliProxyApiUrl: serverUrl, managementKey: SECRET_KEY });
    const resXai = await xai.initiateOAuth();
    assert.equal(resXai.success, true);
    assert.equal(resXai.flow, 'device_code');
    assert.equal(resXai.userCode, 'XAI-8888');
    assert.equal(resXai.verificationUri, 'https://auth.x.ai/activate');

    // Verify Secret is NOT in returned payload
    assert.equal(JSON.stringify(resXai).includes(SECRET_KEY), false, 'Secret key must not leak to caller');

    // Poll status
    const statusXai = await xai.checkOAuthStatus(resXai.state);
    assert.equal(statusXai.status, 'wait');

    // Cancel session
    const cancelXai = await xai.cancelOAuth(resXai.state);
    assert.equal(cancelXai, true);

  } finally {
    await new Promise(resolve => mockServer.close(resolve));
  }
});
