import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { syncManagementKey } from '../src/sync_secret.js';
import { loadConfig } from '../src/config.js';

test('Hardening: Secret synchronization without process arguments or command injection', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'sync-secret-test-'));

  try {
    const configPath = path.join(tempDir, 'config.yaml');
    const envPath = path.join(tempDir, 'manager.env');

    // Secret containing tricky shell characters ($ ` " \ ; &&)
    const complexSecret = `sec$ret\` with"double' single\\slash #hash=equals;&&`;

    const yamlContent = `
port: 8317
host: "0.0.0.0"

management:
  allow-remote: false
  secret-key: ${JSON.stringify(complexSecret)}
`;

    const envContent = `
PORT=8320
HOST=0.0.0.0
CLIPROXYAPI_URL=http://127.0.0.1:8317
CLIPROXYAPI_MANAGEMENT_KEY=
CLIPROXYAPI_MANAGEMENT_KEY="stale duplicate"
AUTH_DIR=/var/lib/cliproxyapi/auths
`;

    fs.writeFileSync(configPath, yamlContent);
    fs.writeFileSync(envPath, envContent);

    // Run safe synchronization
    assert.equal(syncManagementKey(configPath, envPath), true);

    // Read back updated manager.env
    const updatedEnv = fs.readFileSync(envPath, 'utf8');

    // Must have exactly one CLIPROXYAPI_MANAGEMENT_KEY line
    const matches = updatedEnv.split('\n').filter(l => l.startsWith('CLIPROXYAPI_MANAGEMENT_KEY='));
    assert.equal(matches.length, 1);

    assert.equal(loadConfig(envPath).cliProxyApiManagementKey, complexSecret);
    assert.equal(JSON.parse(matches[0].slice('CLIPROXYAPI_MANAGEMENT_KEY='.length)), complexSecret);

  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
