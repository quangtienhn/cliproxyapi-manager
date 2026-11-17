import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { LocalAuthStore, maskEmail, validateAuthFilename } from '../src/auth_store.js';

test('AuthStore: Masking and Filename Validation', () => {
  assert.equal(maskEmail('coocaa.s3g@gmail.com'), 'coo***@gmail.com');
  assert.equal(maskEmail('user@test.org'), 'use***@test.org');
  assert.equal(maskEmail(''), '');

  // Filename safety check
  assert.equal(validateAuthFilename('codex-user-hash.json'), true);
  assert.equal(validateAuthFilename('xai-user.json'), true);
  assert.equal(validateAuthFilename('../../etc/passwd'), false);
  assert.equal(validateAuthFilename('codex.json; rm -rf /'), false);
  assert.equal(validateAuthFilename('codex\\user.json'), false);
  assert.equal(validateAuthFilename('test.txt'), false);
});

test('AuthStore: Credential parsing, listing, backup and deletion', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'authstore-test-'));
  const backupDir = path.join(tempDir, 'backups');

  try {
    // Write synthetic test credentials (NEVER real credentials)
    const codexFixture = {
      type: 'codex',
      email: 'synthetic.developer@openai.test',
      plan_type: 'plus',
      access_token: 'synthetic_secret_access_token_do_not_leak',
      refresh_token: 'synthetic_secret_refresh_token_do_not_leak',
      last_refresh: new Date().toISOString()
    };

    const xaiFixture = {
      type: 'xai',
      sub: 'usr_mock_12345',
      email: 'synthetic.grok@xai.test',
      access_token: 'synthetic_grok_token',
      refresh_token: 'synthetic_grok_refresh'
    };

    fs.writeFileSync(path.join(tempDir, 'codex-dev-123.json'), JSON.stringify(codexFixture));
    fs.writeFileSync(path.join(tempDir, 'xai-grok-456.json'), JSON.stringify(xaiFixture));

    const store = new LocalAuthStore(tempDir);
    const accounts = store.listAccounts();

    assert.equal(accounts.length, 2);

    // Verify secret redaction: NO access_token or refresh_token in listed object
    for (const acc of accounts) {
      assert.equal(acc.access_token, undefined, 'Must not expose access_token');
      assert.equal(acc.refresh_token, undefined, 'Must not expose refresh_token');
      assert.ok(acc.emailMasked.includes('***'), 'Email must be masked');
      assert.equal(acc.hasRefreshToken, true);
    }

    // Backup
    const backupResult = store.createBackup(backupDir);
    assert.ok(backupResult);
    assert.equal(backupResult.count, 2);
    assert.ok(fs.existsSync(backupResult.targetDir));

    // Delete single account
    const deleted = store.deleteAccount('codex-dev-123.json');
    assert.equal(deleted, true);

    const remaining = store.listAccounts();
    assert.equal(remaining.length, 1);
    assert.equal(remaining[0].filename, 'xai-grok-456.json');

    // Attempt invalid deletion (path traversal)
    assert.throws(() => {
      store.deleteAccount('../etc/passwd');
    }, /Invalid filename format/);

  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
