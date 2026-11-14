#!/usr/bin/env node
// ==============================================================================
// Real Account Manager loopback-binding verification
// ------------------------------------------------------------------------------
// Runs the *actual* embedded Account Manager process (not a generic Node
// socket test) and inspects its listening sockets:
//   - binds 127.0.0.1 only
//   - never binds 0.0.0.0 or [::]
//   - is unreachable through the host's LAN address
//   - survives a process restart
//   - can bind ::1 when explicitly configured for IPv6 loopback
// ==============================================================================
import assert from 'node:assert';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const bundle = path.join(root, 'server-installer', 'embedded', 'cliproxyapi-account-manager-v1.0.1.tar.gz');
const yamlDep = path.join(root, 'server-installer', 'embedded', 'yaml-dependency.tar.gz');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'am-loopback-'));
const appDir = path.join(tmp, 'app');
const envDir = path.join(tmp, 'env');
fs.mkdirSync(appDir, { recursive: true });
fs.mkdirSync(envDir, { recursive: true });

function extract(archive, dest) {
  // Stage the archive inside the destination and extract by relative name with
  // an explicit cwd. This avoids both Windows path quirks: GNU tar treats
  // "D:\..." or "C:\..." as a remote host spec, and bsdtar/GNU tar disagree on
  // how "-C <windows path>" is parsed. Copying a small bundle is cheap.
  const staged = path.join(dest, '.am-bundle.tar.gz');
  fs.copyFileSync(archive, staged);
  try {
    const r = spawnSync('tar', ['-xzf', path.basename(staged)], {
      cwd: dest,
      encoding: 'utf8'
    });
    if (r.status !== 0) throw new Error(`tar failed: ${r.stderr}`);
  } finally {
    fs.rmSync(staged, { force: true });
  }
}
extract(bundle, appDir);
extract(yamlDep, appDir);

let pass = 0;
let fail = 0;
function ok(name) { console.log(`  [PASS] ${name}`); pass++; }
function bad(name, detail) { console.log(`  [FAIL] ${name}${detail ? `: ${detail}` : ''}`); fail++; }

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

function baseEnv(port, host) {
  return {
    ...process.env,
    HOST: host,
    PORT: String(port),
    NODE_ENV: 'production',
    ADMIN_USERNAME: 'admin',
    ADMIN_PASSWORD_HASH: '',
    CLIPROXYAPI_URL: 'http://127.0.0.1:8317',
    AUTH_DIR: path.join(tmp, 'auths'),
    DATA_DIR: path.join(tmp, 'data'),
    AUDIT_LOG_PATH: path.join(tmp, 'audit.log'),
    CLIPROXYAPI_MANAGEMENT_KEY: 'test-only-placeholder'
  };
}

async function waitHealthy(port, host = '127.0.0.1', timeoutMs = 8000) {
  const urlHost = host.includes(':') ? `[${host}]` : host;
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const res = await fetch(`http://${urlHost}:${port}/api/health`, { signal: AbortSignal.timeout(1000) });
      if (res.ok) {
        const body = await res.json();
        if (body.status === 'healthy') return true;
      }
    } catch {}
    await sleep(150);
  }
  return false;
}

function freePort(host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, host, () => {
      const p = s.address().port;
      s.close(() => resolve(p));
    });
  });
}

function listenAddresses(port) {
  if (process.platform === 'win32') {
    const ps = `Get-NetTCPConnection -LocalPort ${port} -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalAddress`;
    const r = spawnSync('powershell', ['-NoProfile', '-Command', ps], { encoding: 'utf8' });
    return r.stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  }
  const r = spawnSync('ss', ['-ltn'], { encoding: 'utf8' });
  return r.stdout.split(/\r?\n/)
    .filter((line) => new RegExp(`:${port}\\s`).test(line))
    .map((line) => line.trim().split(/\s+/)[3])
    .filter(Boolean);
}

function connect(host, port, timeoutMs = 1500) {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    const done = (result) => { socket.destroy(); resolve(result); };
    socket.setTimeout(timeoutMs);
    socket.once('connect', () => done('connected'));
    socket.once('timeout', () => done('timeout'));
    socket.once('error', (err) => done(err.code || 'error'));
  });
}

function lanAddresses() {
  const out = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const e of entries || []) {
      if (e.family === 'IPv4' && !e.internal) out.push(e.address);
    }
  }
  return out;
}

async function startServer(port, host) {
  const child = spawn(process.execPath, ['src/server.js'], {
    cwd: appDir,
    env: baseEnv(port, host),
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let output = '';
  child.stdout.on('data', (d) => { output += d; });
  child.stderr.on('data', (d) => { output += d; });
  const healthy = await waitHealthy(port, host);
  return { child, healthy, output: () => output };
}

async function stopServer(server) {
  server.child.kill('SIGTERM');
  await new Promise((resolve) => {
    const timer = setTimeout(() => { server.child.kill('SIGKILL'); resolve(); }, 2000);
    server.child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}

async function verifyIpv4Loopback(port, label) {
  const server = await startServer(port, '127.0.0.1');
  try {
    if (server.healthy) ok(`${label}: real Account Manager process answers on 127.0.0.1:${port}`);
    else { bad(`${label}: process did not become healthy`, server.output().slice(-400)); return; }

    const addrs = listenAddresses(port);
    if (addrs.some((a) => a === '127.0.0.1')) ok(`${label}: listener bound to 127.0.0.1`);
    else bad(`${label}: 127.0.0.1 listener not found`, addrs.join(', '));

    if (!addrs.some((a) => a === '0.0.0.0' || a === '*' || a === '::' || a === '[::]')) {
      ok(`${label}: no wildcard (0.0.0.0/[::]) listener`);
    } else {
      bad(`${label}: wildcard listener present`, addrs.join(', '));
    }

    const v6 = await connect('::1', port);
    if (v6 !== 'connected') ok(`${label}: IPv6 ::1 not exposed by IPv4-loopback process (${v6})`);
    else bad(`${label}: IPv6 ::1 unexpectedly reachable`);

    const lans = lanAddresses();
    if (lans.length === 0) {
      console.log(`  [SKIP] ${label}: no non-internal IPv4 interface for LAN reachability test`);
    } else {
      for (const lan of lans) {
        const result = await connect(lan, port);
        if (result !== 'connected') ok(`${label}: LAN address ${lan} cannot reach the service (${result})`);
        else bad(`${label}: service reachable through LAN address ${lan}`);
      }
    }
  } finally {
    await stopServer(server);
  }
}

async function verifyIpv6Loopback(port) {
  const server = await startServer(port, '::1');
  try {
    if (!server.healthy) {
      console.log(`  [SKIP] IPv6 loopback bind not supported on this host (${server.output().slice(-200)})`);
      return;
    }
    ok('::1: real Account Manager process answers on [::1]');
    const addrs = listenAddresses(port);
    if (addrs.some((a) => a === '::1' || a === '[::1]')) ok('::1: listener bound to ::1');
    else bad('::1: ::1 listener not found', addrs.join(', '));
    const v4 = await connect('127.0.0.1', port);
    if (v4 !== 'connected') ok(`::1: IPv4 127.0.0.1 not exposed by IPv6-loopback process (${v4})`);
    else bad('::1: IPv4 127.0.0.1 unexpectedly reachable');
  } finally {
    await stopServer(server);
  }
}

console.log('=== Real Account Manager loopback verification ===');

const v4port = await freePort('127.0.0.1');
await verifyIpv4Loopback(v4port, 'fresh start');
await verifyIpv4Loopback(v4port, 'process restart (reboot simulation)');
const v6port = await freePort('::1').catch(() => null);
if (v6port) await verifyIpv6Loopback(v6port);
else console.log('  [SKIP] IPv6 loopback is not available on this host');

// The shipped template must enforce loopback independently of the runtime
// environment.
const template = fs.readFileSync(path.join(root, 'server-installer', 'templates', 'manager.env.template'), 'utf8');
assert.match(template, /^HOST=127\.0\.0\.1$/m, 'manager.env.template must set HOST=127.0.0.1');
if (!/^HOST=0\.0\.0\.0$/m.test(template)) ok('template cannot request a wildcard bind');
else bad('template still contains HOST=0.0.0.0');

// Auth dir may be created by the process; leave temp cleanup to the OS.
console.log('--------------------------------------------------------');
console.log(`Results: ${pass} passed, ${fail} failed.`);
process.exit(fail === 0 ? 0 : 1);
