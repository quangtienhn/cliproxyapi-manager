import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createServer } from '../src/server.js';

test('Blocker 1: Persistent Administrator Bootstrap and Restart Survival', async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'admin-persist-test-'));
  const dataDir = path.join(tempDir, 'data');
  const authDir = path.join(tempDir, 'auths');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.mkdirSync(authDir, { recursive: true });

  const adminFile = path.join(dataDir, 'admin.json');

  // 1. Instance 1: Initial State (requiresSetup = true)
  const inst1 = createServer({
    port: 8410,
    host: '127.0.0.1',
    dataDir,
    authDir,
    adminPasswordHash: '', // force empty in config
    auditLogPath: path.join(tempDir, 'audit.log')
  });

  await new Promise(resolve => inst1.server.listen(8410, '127.0.0.1', resolve));

  try {
    // Check status before setup
    const resStatusPre = await fetch('http://127.0.0.1:8410/api/status');
    const statusPre = await resStatusPre.json();
    assert.equal(statusPre.requiresSetup, true);

    // Initial setup with password
    const password = 'SuperSecureMasterPassword123!';
    const resSetup = await fetch('http://127.0.0.1:8410/api/setup', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password })
    });
    assert.equal(resSetup.status, 200);

    // Verify admin.json was persisted on disk and NO plaintext password exists
    assert.ok(fs.existsSync(adminFile), 'admin.json must be persisted on disk');
    const rawSaved = fs.readFileSync(adminFile, 'utf8');
    const parsedSaved = JSON.parse(rawSaved);
    assert.equal(parsedSaved.username, 'admin');
    assert.ok(parsedSaved.passwordHash.startsWith('scrypt:'), 'Must be scrypt hashed');
    assert.equal(rawSaved.includes(password), false, 'Plaintext password must never be stored');

    // Attempt second setup on running instance (must fail)
    const resSetupDup = await fetch('http://127.0.0.1:8410/api/setup', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'attacker', password: 'AttackerPassword123!' })
    });
    assert.equal(resSetupDup.status, 400);

  } finally {
    await new Promise(resolve => inst1.server.close(resolve));
  }

  // 2. Instance 2: RESTART SIMULATION using same dataDir (independent server instance)
  const inst2 = createServer({
    port: 8411,
    host: '127.0.0.1',
    dataDir,
    authDir,
    adminPasswordHash: '', // env still empty, must load from dataDir/admin.json
    auditLogPath: path.join(tempDir, 'audit.log')
  });

  await new Promise(resolve => inst2.server.listen(8411, '127.0.0.1', resolve));

  try {
    // Verify status on new instance reports requiresSetup = false
    const resStatusPost = await fetch('http://127.0.0.1:8411/api/status');
    const statusPost = await resStatusPost.json();
    assert.equal(statusPost.requiresSetup, false, 'Setup must not be required after restart');

    // Verify setup cannot be repeated after restart
    const resSetupPostRestart = await fetch('http://127.0.0.1:8411/api/setup', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'attacker', password: 'AttackerPassword123!' })
    });
    assert.equal(resSetupPostRestart.status, 400, 'Setup must remain disabled post-restart');

    // Verify login with correct password works
    const resLoginGood = await fetch('http://127.0.0.1:8411/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password: 'SuperSecureMasterPassword123!' })
    });
    assert.equal(resLoginGood.status, 200, 'Login with original password must succeed after restart');

    // Verify login with wrong password fails
    const resLoginBad = await fetch('http://127.0.0.1:8411/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'admin', password: 'WrongPassword' })
    });
    assert.equal(resLoginBad.status, 401, 'Login with wrong password must fail');

  } finally {
    await new Promise(resolve => inst2.server.close(resolve));
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
