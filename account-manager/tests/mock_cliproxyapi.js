import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// authDir is optional. When provided, a status change is persisted into the
// auth file exactly like CLIProxyAPI does, so Account Manager can verify the
// state after the API call.
export function createMockCLIProxyAPI(port = 8399, accountOverrides = null, authDir = null) {
  const accounts = accountOverrides || [
    {
      id: 'codex-mock-user@example.com-hash.json',
      provider: 'codex',
      label: 'OpenAI Mock Account',
      email: 'mock-user@example.com',
      storage: {
        access_token: 'synthetic_mock_access_token_12345',
        refresh_token: 'synthetic_mock_refresh_token_67890',
        plan_type: 'free'
      }
    },
    {
      id: 'xai-mock-grok@example.com-hash.json',
      provider: 'xai',
      label: 'xAI Grok Mock',
      email: 'mock-grok@example.com',
      storage: {
        access_token: 'synthetic_mock_grok_token_99999',
        refresh_token: 'synthetic_mock_grok_refresh_88888'
      }
    }
  ];

  const models = [
    { id: 'gpt-4o-mini', object: 'model' },
    { id: 'gpt-4o', object: 'model' },
    { id: 'o1-preview', object: 'model' },
    { id: 'grok-2', object: 'model' },
    { id: 'grok-2-mini', object: 'model' }
  ];

  let pendingOAuthSession = null;
  // Test-only state for CLIProxyAPI's native disabled flag.
  const disabledAccounts = new Map();

  function readBody(req) {
    return new Promise((resolve, reject) => {
      let body = '';
      req.on('data', chunk => { body += chunk; });
      req.on('end', () => {
        try { resolve(body ? JSON.parse(body) : {}); } catch (err) { reject(err); }
      });
      req.on('error', reject);
    });
  }

  const server = http.createServer(async (req, res) => {
    const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = parsedUrl.pathname;
    const method = req.method;

    function sendJson(code, data) {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    }

    // 1. /v1/models
    if (method === 'GET' && pathname === '/v1/models') {
      return sendJson(200, { data: models });
    }

    // 2. /v1/chat/completions - simulate CLIProxyAPI account selection:
    // disabled credentials are never chosen for a new request.
    if (method === 'POST' && pathname === '/v1/chat/completions') {
      const selected = accounts.find(a => disabledAccounts.get(a.id) !== true);
      if (!selected) {
        return sendJson(503, { error: 'no enabled credentials available' });
      }
      return sendJson(200, {
        id: 'chatcmpl-mock-123',
        model: 'gpt-4o-mini',
        selected: selected.id,
        choices: [
          {
            index: 0,
            message: { role: 'assistant', content: 'Mock response: Hello from mock CLIProxyAPI gateway!' }
          }
        ]
      });
    }

    // 2a. /v8/management/credentials/status (CLIProxyAPI v8.0.61 compatible)
    if (method === 'PATCH' && pathname === '/v8/management/credentials/status') {
      let body;
      try {
        body = await readBody(req);
      } catch {
        return sendJson(400, { error: 'invalid request body' });
      }
      if (!body.name || typeof body.disabled !== 'boolean') {
        return sendJson(400, { error: 'name and disabled are required' });
      }
      if (!accounts.some(a => a.id === body.name)) {
        return sendJson(404, { error: 'auth file not found' });
      }
      // Test-only failure injection; no credentials are involved.
      if (body.name.includes('failing')) {
        return sendJson(500, { error: 'simulated management failure' });
      }
      disabledAccounts.set(body.name, body.disabled);
      if (authDir) {
        const filePath = path.join(authDir, path.basename(body.name));
        if (fs.existsSync(filePath)) {
          try {
            const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
            // Mirror CLIProxyAPI v8: authoritative top-level flag plus the
            // legacy metadata copy (which it does not clean up).
            data.disabled = body.disabled;
            if (!data.metadata || typeof data.metadata !== 'object') data.metadata = {};
            data.metadata.disabled = body.disabled;
            fs.writeFileSync(filePath, JSON.stringify(data), { mode: 0o600 });
          } catch {
            return sendJson(500, { error: 'simulated auth file write failure' });
          }
        }
      }
      return sendJson(200, { status: 'ok', disabled: body.disabled });
    }

    // 3. /v8/management/oauth/auth-url
    if (method === 'POST' && pathname === '/v8/management/oauth/auth-url') {
      const provider = parsedUrl.searchParams.get('provider');
      const state = `mock-state-${Date.now()}`;
      pendingOAuthSession = { state, provider, status: 'wait', ticks: 0 };

      if (provider === 'xai') {
        return sendJson(200, {
          status: 'ok',
          flow: 'device',
          state,
          url: 'https://auth.x.ai/activate',
          user_code: 'MCK-9999',
          expires_in: 1800
        });
      } else {
        return sendJson(200, {
          status: 'ok',
          state,
          url: `https://auth.openai.com/authorize?state=${state}`
        });
      }
    }

    // 4. /v8/management/oauth/status
    if (method === 'GET' && pathname === '/v8/management/oauth/status') {
      const state = parsedUrl.searchParams.get('state');
      if (!pendingOAuthSession || pendingOAuthSession.state !== state) {
        return sendJson(404, { error: 'session not found' });
      }

      // Simulate completion after 2 polls
      pendingOAuthSession.ticks++;
      if (pendingOAuthSession.ticks >= 2) {
        pendingOAuthSession.status = 'ok';
      }

      return sendJson(200, {
        status: pendingOAuthSession.status,
        saved: pendingOAuthSession.status === 'ok',
        adopted: pendingOAuthSession.status === 'ok'
      });
    }

    // 5. /v8/management/oauth/session
    if (method === 'DELETE' && pathname === '/v8/management/oauth/session') {
      pendingOAuthSession = null;
      return sendJson(200, { success: true });
    }

    // 404
    sendJson(404, { error: 'Not found on mock server' });
  });

  return {
    server,
    listen: () => new Promise(resolve => server.listen(port, '127.0.0.1', resolve)),
    close: () => new Promise(resolve => server.close(resolve)),
    url: `http://127.0.0.1:${port}`,
    accountIds: accounts.map(a => a.id),
    isDisabled: (name) => disabledAccounts.get(name) === true
  };
}
