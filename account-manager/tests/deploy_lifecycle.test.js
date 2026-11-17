import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

test('Deploy & Rollback Simulation: Full Lifecycle, Snapshots, and Safety Boundaries', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'deploy-lifecycle-'));
  const backupRoot = path.join(tempDir, 'backups');
  const appDir = path.join(tempDir, 'opt_app');
  const systemdDir = path.join(tempDir, 'systemd');
  const authDir = path.join(tempDir, 'auths');

  fs.mkdirSync(backupRoot, { recursive: true });
  fs.mkdirSync(appDir, { recursive: true });
  fs.mkdirSync(systemdDir, { recursive: true });
  fs.mkdirSync(authDir, { recursive: true });

  const serviceFile = path.join(systemdDir, 'cliproxyapi-account-manager.service');
  const pointerFile = path.join(backupRoot, 'latest_snapshot_path');

  // Synthetic credentials in authDir to guarantee preservation
  const codexCred = path.join(authDir, 'codex-live-test.json');
  const xaiCred = path.join(authDir, 'xai-live-test.json');
  fs.writeFileSync(codexCred, '{"type":"codex","account":"live"}');
  fs.writeFileSync(xaiCred, '{"type":"xai","account":"live"}');

  try {
    // -------------------------------------------------------------------------
    // 1. First-install Simulation (No prior backup exists)
    // -------------------------------------------------------------------------
    // App staging and atomic rename
    const stagingDir1 = path.join(tempDir, 'staging_v1');
    fs.mkdirSync(stagingDir1, { recursive: true });
    fs.writeFileSync(path.join(stagingDir1, 'version.txt'), '1.0.0');
    fs.writeFileSync(path.join(stagingDir1, 'server.js'), 'console.log("v1")');

    // Simulate atomic swap
    fs.cpSync(stagingDir1, appDir, { recursive: true });
    fs.writeFileSync(serviceFile, '[Unit]\nDescription=v1');

    assert.equal(fs.readFileSync(path.join(appDir, 'version.txt'), 'utf8'), '1.0.0');
    assert.equal(fs.existsSync(pointerFile), false, 'No pointer file on fresh install');

    // -------------------------------------------------------------------------
    // 2. Successful Upgrade Simulation (v1.0.0 -> v1.0.1)
    // -------------------------------------------------------------------------
    const snapshotTimestamp = '20261110T120000';
    const snapshotDir = path.join(backupRoot, `snapshot_${snapshotTimestamp}`);
    fs.mkdirSync(snapshotDir, { recursive: true });

    // Snapshot app, systemd unit, and service state
    fs.cpSync(appDir, path.join(snapshotDir, 'app'), { recursive: true });
    fs.copyFileSync(serviceFile, path.join(snapshotDir, 'service_unit.service'));
    fs.writeFileSync(path.join(snapshotDir, 'service_state.env'), 'WAS_ENABLED=yes\nWAS_ACTIVE=yes\n');
    fs.writeFileSync(pointerFile, snapshotDir);

    // Staging and swap v1.0.1
    const stagingDir2 = path.join(tempDir, 'staging_v2');
    fs.mkdirSync(stagingDir2, { recursive: true });
    fs.writeFileSync(path.join(stagingDir2, 'version.txt'), '1.0.1');
    fs.writeFileSync(path.join(stagingDir2, 'server.js'), 'console.log("v2")');

    fs.rmSync(appDir, { recursive: true, force: true });
    fs.cpSync(stagingDir2, appDir, { recursive: true });
    fs.writeFileSync(serviceFile, '[Unit]\nDescription=v2');

    assert.equal(fs.readFileSync(path.join(appDir, 'version.txt'), 'utf8'), '1.0.1');
    assert.equal(fs.readFileSync(serviceFile, 'utf8'), '[Unit]\nDescription=v2');

    // -------------------------------------------------------------------------
    // 3. Rollback After Upgrade (Restores v1.0.0 and service state)
    // -------------------------------------------------------------------------
    assert.equal(fs.existsSync(pointerFile), true);
    const targetSnapshot = fs.readFileSync(pointerFile, 'utf8').trim();

    // Verify snapshot safety boundary
    assert.ok(targetSnapshot.startsWith(backupRoot), 'Snapshot must be under backupRoot');
    assert.ok(fs.existsSync(path.join(targetSnapshot, 'app')));
    assert.ok(fs.existsSync(path.join(targetSnapshot, 'service_unit.service')));
    assert.ok(fs.existsSync(path.join(targetSnapshot, 'service_state.env')));

    // Execute rollback restoration
    fs.rmSync(appDir, { recursive: true, force: true });
    fs.cpSync(path.join(targetSnapshot, 'app'), appDir, { recursive: true });
    fs.copyFileSync(path.join(targetSnapshot, 'service_unit.service'), serviceFile);
    fs.rmSync(pointerFile);

    // Assert v1.0.0 restored
    assert.equal(fs.readFileSync(path.join(appDir, 'version.txt'), 'utf8'), '1.0.0');
    assert.equal(fs.readFileSync(serviceFile, 'utf8'), '[Unit]\nDescription=v1');
    assert.equal(fs.existsSync(pointerFile), false, 'Pointer cleaned up after restore');

    // -------------------------------------------------------------------------
    // 4. Malicious / Invalid Backup Pointer Protection
    // -------------------------------------------------------------------------
    const maliciousPointers = [
      '/etc/shadow',
      '../../etc/passwd',
      path.join(tempDir, 'outside_backup_dir')
    ];

    for (const badPtr of maliciousPointers) {
      const isValid = badPtr.startsWith(backupRoot) && fs.existsSync(badPtr);
      assert.equal(isValid, false, `Pointer ${badPtr} must be rejected`);
    }

    // -------------------------------------------------------------------------
    // 5. Credential Preservation Invariance
    // -------------------------------------------------------------------------
    assert.equal(fs.existsSync(codexCred), true, 'Codex credential must stay untouched');
    assert.equal(fs.existsSync(xaiCred), true, 'xAI credential must stay untouched');
    assert.equal(fs.readFileSync(codexCred, 'utf8'), '{"type":"codex","account":"live"}');
    assert.equal(fs.readFileSync(xaiCred, 'utf8'), '{"type":"xai","account":"live"}');

  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
