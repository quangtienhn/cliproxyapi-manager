#!/usr/bin/env node
// Unit tests for the HAOS add-on host-key pinning parser.
import assert from 'node:assert';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.resolve(here, '..', 'haos-addon', 'rootfs', 'hostkey.mjs');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hostkey-test-'));
const ED = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleHostKeyMaterial0123456789';
let pass = 0;
let fail = 0;

function run(host, port, input) {
  const out = path.join(tmp, `kh-${Math.random().toString(16).slice(2)}`);
  const r = spawnSync(process.execPath, [script, host, String(port), out], { input });
  return { ...r, out };
}

function ok(name, fn) {
  try { fn(); console.log(`  [PASS] ${name}`); pass++; }
  catch (e) { console.log(`  [FAIL] ${name}: ${e.message}`); fail++; }
}

console.log('=== HAOS host key pinning unit tests ===');

ok('default port uses bare host', () => {
  const r = run('server.example.com', 22, `${ED}\n`);
  assert.strictEqual(r.status, 0, r.stderr?.toString());
  assert.match(fs.readFileSync(r.out, 'utf8'), /^server\.example\.com ssh-ed25519 /);
});

ok('non-default port uses [host]:port', () => {
  const r = run('server.example.com', 2222, `${ED}\n`);
  assert.strictEqual(r.status, 0);
  assert.match(fs.readFileSync(r.out, 'utf8'), /^\[server\.example\.com\]:2222 ssh-ed25519 /);
});

ok('IPv6 literal is bracketed', () => {
  const r = run('::1', 22, `${ED}\n`);
  assert.strictEqual(r.status, 0);
  assert.match(fs.readFileSync(r.out, 'utf8'), /^\[::1\]:22 ssh-ed25519 /);
});

ok('comment and blank lines ignored', () => {
  const r = run('h', 22, `# header\n\n${ED}\n`);
  assert.strictEqual(r.status, 0);
  assert.strictEqual(fs.readFileSync(r.out, 'utf8').trim().split('\n').length, 1);
});

ok('optional host-name prefix stripped', () => {
  const r = run('h', 22, `h ${ED}\n`);
  assert.strictEqual(r.status, 0);
});

ok('empty input rejected', () => {
  assert.strictEqual(run('h', 22, '').status, 2);
});

ok('invalid key type rejected', () => {
  assert.strictEqual(run('h', 22, 'ssh-nope AAAABBBB\n').status, 2);
});

ok('invalid base64 rejected', () => {
  assert.strictEqual(run('h', 22, 'ssh-ed25519 not*base64 material\n').status, 2);
});

ok('shell metacharacters in host rejected', () => {
  assert.strictEqual(run('evil;touch /tmp/x', 22, `${ED}\n`).status, 2);
});

ok('out-of-range port rejected', () => {
  assert.strictEqual(run('h', 70000, `${ED}\n`).status, 2);
});

ok('known_hosts written with mode 0600', () => {
  const r = run('h', 22, `${ED}\n`);
  assert.strictEqual(r.status, 0);
  if (process.platform !== 'win32') {
    assert.strictEqual(fs.statSync(r.out).mode & 0o777, 0o600);
  }
});

fs.rmSync(tmp, { recursive: true, force: true });
console.log('--------------------------------------------------------');
console.log(`Results: ${pass} passed, ${fail} failed.`);
if (fail > 0) process.exit(1);
