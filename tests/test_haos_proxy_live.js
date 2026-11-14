import assert from 'node:assert';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

console.log('=== Running HAOS Ingress Reverse Proxy Edge & Concurrency Tests ===');

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.once('error', reject);
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

async function waitFor(url, timeoutMs = 5000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.ok) return res;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timeout waiting for ${url}`);
}

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'haos-proxy-'));
fs.writeFileSync(path.join(dataDir, 'id_ed25519.pub'), 'ssh-ed25519 AAAATestKeyOnly amtunnel@test\n');
fs.writeFileSync(path.join(dataDir, 'options.json'), JSON.stringify({
  server_host: 'server.example.com',
  server_port: 22,
  server_user: 'amtunnel',
  remote_host: '127.0.0.1',
  remote_port: 8320,
  host_key: 'ssh-ed25519 AAAATestHostKey'
}));

const upstreamPort = await freePort();
const proxyPort = await freePort();

const upstream = http.createServer((req, res) => {
  if (req.url === '/api/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy', uptime: 123 }));
    return;
  }
  if (req.url === '/api/accounts') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Set-Cookie': ['session=test_cookie_123; Path=/; HttpOnly; SameSite=Lax']
    });
    res.end(JSON.stringify({ accounts: ['user@example.com'], count: 1 }));
    return;
  }
  if (req.url === '/redirect') {
    res.writeHead(302, { Location: '/api/accounts' });
    res.end();
    return;
  }
  if (req.url === '/page') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end('<html><head><script src="/app.js"></script></head><body><a href="/api/health">Link</a><style>body{background:url(/bg.png)}</style></body></html>');
    return;
  }
  res.writeHead(404);
  res.end('Not Found');
});

let proxyProc;
let exitCode = 0;

try {
  await new Promise((resolve, reject) => {
    upstream.once('error', reject);
    upstream.listen(upstreamPort, '127.0.0.1', resolve);
  });

  proxyProc = spawn(process.execPath, ['haos-addon/rootfs/proxy.mjs'], {
    env: {
      ...process.env,
      PORT: String(proxyPort),
      UPSTREAM_PORT: String(upstreamPort),
      DATA_DIR: dataDir
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let proxyLog = '';
  proxyProc.stdout.on('data', (d) => { proxyLog += d; });
  proxyProc.stderr.on('data', (d) => { proxyLog += d; });

  const base = `http://127.0.0.1:${proxyPort}`;
  await waitFor(`${base}/healthz`);

  const ingressPrefix = '/api/hassio_ingress/token_xyz';

  const healthRes = await fetch(`${base}/healthz`);
  const healthJson = await healthRes.json();
  assert.strictEqual(healthJson.status, 'healthy', 'Healthz returns healthy when upstream is active');

  const accRes = await fetch(`${base}${ingressPrefix}/api/accounts`, {
    headers: { 'X-Ingress-Path': ingressPrefix }
  });
  const accJson = await accRes.json();
  assert.strictEqual(accJson.count, 1, 'Accounts fetched via Ingress');
  const setCookie = accRes.headers.get('set-cookie');
  assert(setCookie.includes(`Path=${ingressPrefix}/`), 'Cookie path rewritten to ingress prefix');

  const redirRes = await fetch(`${base}${ingressPrefix}/redirect`, {
    redirect: 'manual',
    headers: { 'X-Ingress-Path': ingressPrefix }
  });
  assert.strictEqual(redirRes.headers.get('location'), `${ingressPrefix}/api/accounts`, 'Redirect location rewritten');

  const pageRes = await fetch(`${base}${ingressPrefix}/page`, {
    headers: { 'X-Ingress-Path': ingressPrefix }
  });
  const pageHtml = await pageRes.text();
  assert(pageHtml.includes(`src="${ingressPrefix}/app.js"`), 'Script src rewritten');
  assert(pageHtml.includes(`href="${ingressPrefix}/api/health"`), 'Link href rewritten');
  assert(pageHtml.includes(`url(${ingressPrefix}/bg.png)`), 'CSS url rewritten');

  const promises = [];
  for (let i = 0; i < 50; i++) {
    promises.push(fetch(`${base}${ingressPrefix}/api/accounts`, {
      headers: { 'X-Ingress-Path': ingressPrefix }
    }).then((r) => r.json()));
  }
  const results = await Promise.all(promises);
  assert.strictEqual(results.length, 50, 'All 50 concurrent requests succeeded');

  const badPath = await fetch(`${base}/api/hassio_ingress/../../etc/passwd`);
  assert([404, 400].includes(badPath.status), 'Path traversal is not forwarded as a file read');

  console.log('[PASS] All HAOS Add-on Ingress proxy tests passed.');
} catch (error) {
  console.error('[FAIL]', error.message);
  exitCode = 1;
} finally {
  if (proxyProc) {
    proxyProc.kill('SIGKILL');
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  await new Promise((resolve) => upstream.close(resolve));
  fs.rmSync(dataDir, { recursive: true, force: true });
}

process.exit(exitCode);
