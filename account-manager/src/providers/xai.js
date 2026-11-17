import { BaseProviderAdapter } from './base.js';

export class XAIAdapter extends BaseProviderAdapter {
  constructor(options = {}) {
    super('xAI (Grok)', 'xai');
    this.cliProxyApiUrl = options.cliProxyApiUrl;
    this.managementKey = options.managementKey;
    this.authDir = options.authDir;
  }

  getLoginFlow() {
    return 'device_code';
  }

  // Uses CLIProxyAPI v8 Management API /v8/management/oauth/auth-url?provider=xai
  async initiateOAuth(options = {}) {
    const url = `${this.cliProxyApiUrl}/v8/management/oauth/auth-url?provider=xai`;
    const headers = {};
    if (this.managementKey) {
      headers['Authorization'] = `Bearer ${this.managementKey}`;
    }

    try {
      const resp = await fetch(url, {
        method: 'POST',
        headers: {
          ...headers,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          provider: 'xai'
        })
      });

      if (!resp.ok) {
        const errorText = await resp.text();
        return {
          success: false,
          error: `Management API error (${resp.status}): ${errorText}`
        };
      }

      const data = await resp.json();
      return {
        success: true,
        flow: 'device_code',
        verificationUri: data.url || 'https://auth.x.ai/activate',
        userCode: data.user_code,
        expiresIn: data.expires_in || 1800,
        state: data.state
      };
    } catch (err) {
      return {
        success: false,
        error: `Failed to connect to CLIProxyAPI: ${err.message}`
      };
    }
  }

  async checkOAuthStatus(state) {
    const url = `${this.cliProxyApiUrl}/v8/management/oauth/status?state=${encodeURIComponent(state)}`;
    const headers = {};
    if (this.managementKey) {
      headers['Authorization'] = `Bearer ${this.managementKey}`;
    }

    try {
      const resp = await fetch(url, { headers });
      if (!resp.ok) {
        return { status: 'error', error: `HTTP ${resp.status}` };
      }
      const data = await resp.json();
      return {
        status: data.status || 'wait', // 'wait', 'ok', 'error'
        error: data.error || null,
        adopted: Boolean(data.adopted),
        saved: Boolean(data.saved)
      };
    } catch (err) {
      return { status: 'error', error: err.message };
    }
  }

  async cancelOAuth(state) {
    const url = `${this.cliProxyApiUrl}/v8/management/oauth/session?state=${encodeURIComponent(state)}`;
    const headers = {};
    if (this.managementKey) {
      headers['Authorization'] = `Bearer ${this.managementKey}`;
    }

    try {
      const resp = await fetch(url, {
        method: 'DELETE',
        headers
      });
      return resp.ok;
    } catch (err) {
      return false;
    }
  }

  async getModels(cliProxyApiUrl) {
    try {
      const targetUrl = cliProxyApiUrl || this.cliProxyApiUrl;
      const resp = await fetch(`${targetUrl}/v1/models`);
      if (!resp.ok) return [];
      const data = await resp.json();
      const list = data.data || data.models || [];
      return list
        .filter(m => {
          const id = (typeof m === 'string' ? m : m.id) || '';
          return id.toLowerCase().startsWith('grok');
        })
        .map(m => (typeof m === 'string' ? { id: m } : m));
    } catch {
      return [];
    }
  }

  async testConnection(cliProxyApiUrl, model = 'grok-2') {
    const targetUrl = cliProxyApiUrl || this.cliProxyApiUrl;
    const startTime = Date.now();
    try {
      const resp = await fetch(`${targetUrl}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model,
          messages: [{ role: 'user', content: 'Ping' }],
          max_tokens: 5
        })
      });

      const durationMs = Date.now() - startTime;
      if (!resp.ok) {
        const text = await resp.text();
        return {
          success: false,
          statusCode: resp.status,
          latencyMs: durationMs,
          error: `API returned ${resp.status}: ${text.slice(0, 150)}`
        };
      }

      const res = await resp.json();
      const content = res.choices?.[0]?.message?.content || 'No response content';
      return {
        success: true,
        statusCode: 200,
        latencyMs: durationMs,
        response: content.trim(),
        model: res.model || model
      };
    } catch (err) {
      return {
        success: false,
        statusCode: 0,
        latencyMs: Date.now() - startTime,
        error: err.message
      };
    }
  }
}
