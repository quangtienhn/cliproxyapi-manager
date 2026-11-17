// Frontend Application Logic
let appState = {
  csrfToken: null,
  username: null,
  activeOAuth: null, // { provider, state, pollTimer }
};

const el = id => document.getElementById(id);

function showAlert(message, type = 'danger') {
  const alertBox = el('alert-box');
  alertBox.className = `alert alert-${type}`;
  alertBox.textContent = message;
  alertBox.classList.remove('hidden');
  setTimeout(() => {
    alertBox.classList.add('hidden');
  }, 6000);
}

// Global API Request wrapper with CSRF injection
async function api(path, options = {}) {
  const headers = options.headers || {};
  if (appState.csrfToken && ['POST', 'PUT', 'DELETE', 'PATCH'].includes(options.method)) {
    headers['x-csrf-token'] = appState.csrfToken;
  }
  options.headers = headers;

  const resp = await fetch(path, options);
  if (resp.status === 401 && !path.includes('/api/status') && !path.includes('/api/login')) {
    showView('login');
    throw new Error('Unauthorized');
  }
  return resp;
}

// Switch UI views
function showView(viewName) {
  el('view-setup').classList.add('hidden');
  el('view-login').classList.add('hidden');
  el('view-dashboard').classList.add('hidden');
  el('header-user').classList.add('hidden');

  if (viewName === 'setup') {
    el('view-setup').classList.remove('hidden');
  } else if (viewName === 'login') {
    el('view-login').classList.remove('hidden');
  } else if (viewName === 'dashboard') {
    el('view-dashboard').classList.remove('hidden');
    el('header-user').classList.remove('hidden');
    el('user-display').textContent = `User: ${appState.username}`;
    loadDashboard();
  }
}

// Initial status check
async function checkAuthStatus() {
  try {
    const res = await api('/api/status');
    const data = await res.json();

    if (data.requiresSetup) {
      showView('setup');
    } else if (data.authenticated) {
      appState.username = data.username;
      appState.csrfToken = data.csrfToken;
      showView('dashboard');
    } else {
      showView('login');
    }
  } catch (err) {
    showAlert(`Failed to connect to backend: ${err.message}`);
    showView('login');
  }
}

// 1. Setup Form Submit
el('form-setup').addEventListener('submit', async e => {
  e.preventDefault();
  const username = el('setup-username').value.trim();
  const password = el('setup-password').value;
  const confirm = el('setup-confirm').value;

  if (password !== confirm) {
    showAlert('Passwords do not match');
    return;
  }

  try {
    const res = await api('/api/setup', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Setup failed');
    showAlert('Administrator setup complete! Please login.', 'success');
    showView('login');
  } catch (err) {
    showAlert(err.message);
  }
});

// 2. Login Form Submit
el('form-login').addEventListener('submit', async e => {
  e.preventDefault();
  const username = el('login-username').value.trim();
  const password = el('login-password').value;

  try {
    const res = await api('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Login failed');

    appState.username = data.username;
    appState.csrfToken = data.csrfToken;
    showView('dashboard');
  } catch (err) {
    showAlert(err.message);
  }
});

// 3. Logout
el('btn-logout').addEventListener('click', async () => {
  try {
    await api('/api/logout', { method: 'POST' });
  } finally {
    appState.username = null;
    appState.csrfToken = null;
    showView('login');
  }
});

// 4. Load Dashboard Data
async function loadDashboard() {
  loadAccounts();
  loadModels();
}

// A paused account is shown as Paused even if its credential is healthy.
// Expired/corrupted credentials keep their own warning badge.
function accountBadge(acc) {
  if (acc.status === 'corrupted') return { text: 'Corrupted', cls: 'badge-danger' };
  if (acc.state === 'paused') return { text: 'Paused', cls: 'badge-warning' };
  if (acc.status === 'expired') return { text: 'Expired', cls: 'badge-danger' };
  if (acc.state === 'active') return { text: 'Active', cls: 'badge-success' };
  return { text: 'Unknown', cls: 'badge-warning' };
}

async function loadAccounts() {
  const tbody = el('accounts-tbody');
  try {
    const res = await api('/api/accounts');
    const data = await res.json();
    const accounts = data.accounts || [];

    // Paused accounts must not count as Active.
    const activeCount = accounts.filter(a => a.state === 'active' && a.status === 'active').length;
    const pausedCount = accounts.filter(a => a.state === 'paused').length;
    el('stat-active').textContent = activeCount;
    if (el('stat-paused')) el('stat-paused').textContent = pausedCount;

    if (accounts.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" class="text-center text-muted">No provider accounts found. Click "+ Add Account" to configure one.</td></tr>';
      return;
    }

    tbody.innerHTML = accounts.map(acc => {
      const badge = accountBadge(acc);
      const lastRefreshStr = acc.lastRefresh ? new Date(acc.lastRefresh).toLocaleString() : 'N/A';
      const safeName = escapeHtml(acc.filename);
      const pauseButton = acc.state === 'paused'
        ? `<button class="btn btn-sm btn-secondary" onclick="setAccountState('${safeName}', 'active')">Resume</button>`
        : `<button class="btn btn-sm btn-secondary" onclick="setAccountState('${safeName}', 'paused')">Pause</button>`;
      return `
        <tr>
          <td><strong>${escapeHtml(acc.provider.toUpperCase())}</strong></td>
          <td>${escapeHtml(acc.emailMasked)}</td>
          <td>${escapeHtml(acc.planType)}</td>
          <td><span class="badge ${badge.cls}">${badge.text}</span></td>
          <td><code>${safeName}</code></td>
          <td>${escapeHtml(lastRefreshStr)}</td>
          <td>
            ${pauseButton}
            <button class="btn btn-sm btn-danger" onclick="deleteAccount('${safeName}')">Delete</button>
          </td>
        </tr>
      `;
    }).join('');
  } catch (err) {
    tbody.innerHTML = `<tr><td colspan="7" class="text-danger text-center">Failed to load accounts: ${err.message}</td></tr>`;
  }
}

async function loadModels() {
  const container = el('models-list');
  try {
    const res = await api('/api/models');
    const data = await res.json();
    const models = data.models || [];

    el('stat-models').textContent = models.length;

    if (models.length === 0) {
      container.innerHTML = '<span class="text-muted">No models returned from CLIProxyAPI.</span>';
      return;
    }

    container.innerHTML = models.map(m => {
      const id = typeof m === 'string' ? m : m.id;
      return `<span class="model-tag">${escapeHtml(id)}</span>`;
    }).join('');
  } catch (err) {
    container.innerHTML = `<span class="text-danger">Failed to load models: ${err.message}</span>`;
  }
}

// 5. Delete Account
window.deleteAccount = async function(filename) {
  const confirmed = confirm(`Are you sure you want to delete credential file "${filename}"?\n\nThis will remove this AI provider account from CLIProxyAPI. An automatic backup will be created.`);
  if (!confirmed) return;

  try {
    const res = await api(`/api/accounts?filename=${encodeURIComponent(filename)}`, {
      method: 'DELETE'
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Failed to delete account');
    showAlert(`Account ${filename} removed successfully.`, 'success');
    loadAccounts();
  } catch (err) {
    showAlert(err.message);
  }
};

// 5a. Pause / Resume Account
window.setAccountState = async function(filename, targetState) {
  const pausing = targetState === 'paused';
  if (pausing) {
    const confirmed = confirm(
      `Pause account "${filename}"?\n\nCLIProxyAPI will stop using it for new requests. ` +
      `Requests already in progress may finish. No credentials are removed; you can Resume later.`
    );
    if (!confirmed) return;
  }

  try {
    const endpoint = pausing ? '/api/accounts/pause' : '/api/accounts/resume';
    const res = await api(`${endpoint}?filename=${encodeURIComponent(filename)}`, {
      method: 'POST'
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Failed to change account state');
    showAlert(data.message || (pausing ? 'Account paused.' : 'Account resumed.'), 'success');
    loadAccounts();
  } catch (err) {
    showAlert(err.message);
  }
};

// 6. Test Inference
el('form-test-provider').addEventListener('submit', async e => {
  e.preventDefault();
  const provider = el('test-provider-select').value;
  const model = el('test-model-input').value.trim();
  const resultBox = el('test-result-box');
  const btn = el('btn-run-test');

  btn.disabled = true;
  btn.textContent = 'Testing...';
  resultBox.classList.remove('hidden');
  resultBox.textContent = `Connecting to ${provider} model ${model} via CLIProxyAPI...`;

  try {
    const res = await api('/api/test-connection', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider, model })
    });
    const data = await res.json();

    if (data.success) {
      resultBox.textContent = `[SUCCESS] (${data.latencyMs}ms)\nStatus: 200 OK\nModel: ${data.model}\nResponse:\n${data.response}`;
      resultBox.style.borderColor = 'var(--success)';
    } else {
      resultBox.textContent = `[FAILED] (${data.latencyMs || 0}ms)\nStatus: ${data.statusCode}\nError: ${data.error}`;
      resultBox.style.borderColor = 'var(--danger)';
    }
  } catch (err) {
    resultBox.textContent = `[REQUEST ERROR]\n${err.message}`;
    resultBox.style.borderColor = 'var(--danger)';
  } finally {
    btn.disabled = false;
    btn.textContent = 'Run Inference Test';
  }
});

// 7. OAuth Modal & Flows
el('btn-open-oauth-modal').addEventListener('click', () => {
  el('oauth-step-select').classList.remove('hidden');
  el('oauth-step-progress').classList.add('hidden');
  el('flow-device-code').classList.add('hidden');
  el('flow-browser').classList.add('hidden');
  el('modal-oauth').classList.remove('hidden');
});

el('btn-close-modal').addEventListener('click', () => {
  cancelActiveOAuth();
  el('modal-oauth').classList.add('hidden');
});

el('btn-cancel-oauth').addEventListener('click', () => {
  cancelActiveOAuth();
  el('oauth-step-select').classList.remove('hidden');
  el('oauth-step-progress').classList.add('hidden');
});

el('btn-start-oauth').addEventListener('click', async () => {
  const selectedProvider = document.querySelector('input[name="oauth-provider"]:checked').value;
  const btn = el('btn-start-oauth');
  btn.disabled = true;
  btn.textContent = 'Starting...';

  try {
    const res = await api('/api/oauth/init', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider: selectedProvider })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Failed to start OAuth');

    el('oauth-step-select').classList.add('hidden');
    el('oauth-step-progress').classList.remove('hidden');

    if (data.flow === 'device_code') {
      // Device Code Flow (xAI)
      el('flow-device-code').classList.remove('hidden');
      el('device-user-code').textContent = data.userCode || '----';
      el('device-auth-url').href = data.verificationUri || 'https://auth.x.ai/activate';
    } else {
      // Browser Flow (Codex)
      el('flow-browser').classList.remove('hidden');
      el('browser-auth-url').href = data.authUrl;
    }

    // Start polling
    startOAuthPolling(selectedProvider, data.state);
  } catch (err) {
    showAlert(err.message);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Start Authentication Flow';
  }
});

function startOAuthPolling(provider, state) {
  cancelActiveOAuth();
  appState.activeOAuth = {
    provider,
    state,
    pollTimer: setInterval(async () => {
      try {
        const res = await api(`/api/oauth/status?provider=${provider}&state=${encodeURIComponent(state)}`);
        const status = await res.json();

        if (status.status === 'ok') {
          cancelActiveOAuth();
          showAlert(`Authentication successful! Account has been added to CLIProxyAPI.`, 'success');
          el('modal-oauth').classList.add('hidden');
          loadAccounts();
          loadModels();
        } else if (status.status === 'error') {
          cancelActiveOAuth();
          showAlert(`Authentication failed: ${status.error || 'Unknown error'}`);
          el('oauth-step-select').classList.remove('hidden');
          el('oauth-step-progress').classList.add('hidden');
        }
      } catch (err) {
        console.error('Polling error:', err);
      }
    }, 3000)
  };
}

function cancelActiveOAuth() {
  if (appState.activeOAuth) {
    if (appState.activeOAuth.pollTimer) {
      clearInterval(appState.activeOAuth.pollTimer);
    }
    api(`/api/oauth/session?provider=${appState.activeOAuth.provider}&state=${encodeURIComponent(appState.activeOAuth.state)}`, {
      method: 'DELETE'
    }).catch(() => {});
    appState.activeOAuth = null;
  }
}

// Refresh buttons
el('btn-refresh-accounts').addEventListener('click', loadAccounts);
el('btn-refresh-models').addEventListener('click', loadModels);

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

// Initialize on page load
checkAuthStatus();
