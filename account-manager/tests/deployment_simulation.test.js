import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { LocalAuthStore } from '../src/auth_store.js';

test('Security & Deployment Simulation: Protected files, Upgrade & Rollback simulation', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'deploy-sim-'));
  const authDir = path.join(tempDir, 'auths');
  fs.mkdirSync(authDir, { recursive: true });

  try {
    // 1. Verify Unrelated file protection
    const store = new LocalAuthStore(authDir);

    // Create a non-auth file (e.g. system file or config file)
    fs.writeFileSync(path.join(authDir, 'config.json'), '{"some":"config"}');
    fs.writeFileSync(path.join(authDir, 'secret_system.txt'), 'confidential');
    fs.writeFileSync(path.join(authDir, 'codex-legit.json'), '{"type":"codex","email":"test@openai.test"}');

    // Attempt to delete non-auth file -> Must be rejected
    assert.throws(() => {
      store.deleteAccount('config.json');
    }, /not a recognized provider credential format/);

    assert.throws(() => {
      store.deleteAccount('other-account.json');
    }, /not a recognized provider credential format/);

    assert.throws(() => {
      store.deleteAccount('secret_system.txt');
    }, /Invalid filename format/);

    // Deleting legitimate codex account -> Must succeed
    assert.equal(store.deleteAccount('codex-legit.json'), true);
    assert.equal(fs.existsSync(path.join(authDir, 'codex-legit.json')), false);
    // Non-auth files must remain untouched
    assert.equal(fs.existsSync(path.join(authDir, 'config.json')), true);
    assert.equal(fs.existsSync(path.join(authDir, 'secret_system.txt')), true);

    // 2. Upgrade & Rollback Simulation (Filesystem Lifecycle)
    const appDir = path.join(tempDir, 'opt_app');
    const backupDir = path.join(tempDir, 'var_backups');
    fs.mkdirSync(appDir, { recursive: true });
    fs.mkdirSync(backupDir, { recursive: true });

    // Simulate v1.0.0 installed
    fs.writeFileSync(path.join(appDir, 'version.txt'), '1.0.0');

    // Upgrade: Backup existing
    const backupPath = path.join(backupDir, 'app_backup_v1');
    fs.cpSync(appDir, backupPath, { recursive: true });
    fs.writeFileSync(path.join(backupDir, 'latest_backup_path'), backupPath);

    // Simulate v1.0.1 deployed
    fs.writeFileSync(path.join(appDir, 'version.txt'), '1.0.1');
    assert.equal(fs.readFileSync(path.join(appDir, 'version.txt'), 'utf8'), '1.0.1');

    // Simulate Rollback: read latest_backup_path and restore
    const prevBackup = fs.readFileSync(path.join(backupDir, 'latest_backup_path'), 'utf8');
    fs.rmSync(appDir, { recursive: true, force: true });
    fs.cpSync(prevBackup, appDir, { recursive: true });

    // Assert v1.0.0 is restored
    assert.equal(fs.readFileSync(path.join(appDir, 'version.txt'), 'utf8'), '1.0.0');

  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
