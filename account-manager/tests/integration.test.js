import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createServer } from '../src/server.js';
import { createMockCLIProxyAPI } from './mock_cliproxyapi.js';

test('Integration & Security: Complete Account Manager Suite', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'am-integration-test-'));
  const authDir = path.join(tempDir, 'auths');
  fs.mkdirSync(authDir, { recursive: true });

  // Synthetic fixture
  fs.writeFileSync(path.join(authDir, 'codex-test.json'), JSON.stringify({
    type: 'codex',
    email: 'tester@example.com',
    plan_type: 'free',
    access_token: 'secret_jwt_access_token_123',
    refresh_token: 'secret_refresh_token_456'
  }));

  // 1. Start mock CLIProxyAPI
  const mockApi = createMockCLIProxyAPI(8399);
  await mockApi.listen();

  // 2. Start Account Manager test instance
  const { server } = createServer({
    port: 8325,
    host: '127.0.0.1',
    cliProxyApiUrl: mockApi.url,
    dataDir: path.join(tempDir, 'data'),
    authDir: authDir,
    auditLogPath: path.join(tempDir, 'audit.log'),
    adminUsername: 'admin',
    adminPasswordHash: '' // force setup mode
  });

  await new Promise(resolve => server.listen(8325, '127.0.0.1', resolve));
  const baseUrl = 'http://127.0.0.1:8325';

  try {
    // Check initial status (requires setup)
    const resStatus1 = await fetch(`${baseUrl}/api/status`);
    const statusData1 = await resStatus1.json();
    assert.equal(statusData1.requiresSetup, true);
    assert.equal(statusData1.authenticated, false);

    // Initial setup
    const resSetup = await fetch(`${baseUrl}/api/setup`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password: 'MasterPassword123!' })
    });
    assert.equal(resSetup.status, 200);

    // Login with wrong password
    const resBadLogin = await fetch(`${baseUrl}/api/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password: 'WrongPassword' })
    });
    assert.equal(resBadLogin.status, 401);

    // Login with correct password
    const resLogin = await fetch(`${baseUrl}/api/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password: 'MasterPassword123!' })
    });
    assert.equal(resLogin.status, 200);
    const loginData = await resLogin.json();
    assert.equal(loginData.success, true);
    assert.ok(loginData.csrfToken);

    // Extract session cookie
    const setCookie = resLogin.headers.get('set-cookie');
    assert.ok(setCookie.includes('am_session='));
    const sessionCookie = setCookie.split(';')[0];

    // Unauthenticated request should be rejected (401)
    const resUnauth = await fetch(`${baseUrl}/api/accounts`);
    assert.equal(resUnauth.status, 401);

    // Authenticated request to list accounts
    const resAccounts = await fetch(`${baseUrl}/api/accounts`, {
      headers: { Cookie: sessionCookie }
    });
    assert.equal(resAccounts.status, 200);
    const accountsData = await resAccounts.json();
    assert.equal(accountsData.total, 1);
    assert.equal(accountsData.accounts[0].emailMasked, 'tes***@example.com');
    // Ensure tokens are NOT leaked
    assert.equal(accountsData.accounts[0].access_token, undefined);

    // CSRF test: POST without CSRF token should be rejected (403)
    const resCsrfFail = await fetch(`${baseUrl}/api/oauth/init`, {
      method: 'POST',
      headers: {
        Cookie: sessionCookie,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ provider: 'xai' })
    });
    assert.equal(resCsrfFail.status, 403);

    // Start OAuth flow (xAI Device Code) with valid CSRF
    const resOauthXai = await fetch(`${baseUrl}/api/oauth/init`, {
      method: 'POST',
      headers: {
        Cookie: sessionCookie,
        'x-csrf-token': loginData.csrfToken,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ provider: 'xai' })
    });
    assert.equal(resOauthXai.status, 200);
    const xaiData = await resOauthXai.json();
    assert.equal(xaiData.flow, 'device_code');
    assert.equal(xaiData.userCode, 'MCK-9999');

    // Poll OAuth status until complete
    let pollStatus = await (await fetch(`${baseUrl}/api/oauth/status?provider=xai&state=${xaiData.state}`, {
      headers: { Cookie: sessionCookie }
    })).json();
    assert.equal(pollStatus.status, 'wait');

    pollStatus = await (await fetch(`${baseUrl}/api/oauth/status?provider=xai&state=${xaiData.state}`, {
      headers: { Cookie: sessionCookie }
    })).json();
    assert.equal(pollStatus.status, 'ok');

    // Fetch models
    const resModels = await fetch(`${baseUrl}/api/models`, {
      headers: { Cookie: sessionCookie }
    });
    const modelsData = await resModels.json();
    assert.ok(modelsData.models.length >= 2);

    // Test connection / inference
    const resInference = await fetch(`${baseUrl}/api/test-connection`, {
      method: 'POST',
      headers: {
        Cookie: sessionCookie,
        'x-csrf-token': loginData.csrfToken,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ provider: 'codex', model: 'gpt-4o-mini' })
    });
    const infData = await resInference.json();
    assert.equal(infData.success, true);
    assert.ok(infData.response.includes('Hello from mock'));

    // Safe Account Deletion
    const resDel = await fetch(`${baseUrl}/api/accounts?filename=codex-test.json`, {
      method: 'DELETE',
      headers: {
        Cookie: sessionCookie,
        'x-csrf-token': loginData.csrfToken
      }
    });
    assert.equal(resDel.status, 200);

    // Verify deletion
    const resAfterDel = await fetch(`${baseUrl}/api/accounts`, {
      headers: { Cookie: sessionCookie }
    });
    const afterDelData = await resAfterDel.json();
    assert.equal(afterDelData.total, 0);

    // Verify audit log exists and no tokens leaked
    const auditContent = fs.readFileSync(path.join(tempDir, 'audit.log'), 'utf8');
    assert.ok(auditContent.includes('LOGIN_SUCCESS'));
    assert.ok(auditContent.includes('ACCOUNT_DELETED'));
    assert.equal(auditContent.includes('secret_jwt_access_token_123'), false, 'Audit log must not contain raw tokens');

  } finally {
    await mockApi.close();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
