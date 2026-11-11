import assert from 'node:assert';
import http from 'node:http';

console.log('=== Running HAOS Ingress Reverse Proxy Edge & Concurrency Tests ===');

// 1. Mock Upstream Server on port 18320
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
    res.writeHead(302, { 'Location': '/api/accounts' });
    res.end();
    return;
  }
  if (req.url === '/page') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end('<html><head><script src="/app.js"></script></head><body><a href="/api/health">Link</a></body></html>');
    return;
  }
  res.writeHead(404);
  res.end('Not Found');
});

upstream.listen(18320, '127.0.0.1', async () => {
  // Start the HAOS proxy.mjs in child process
  const { spawn } = await import('node:child_process');
  const proxyProc = spawn(process.execPath, ['haos-addon/rootfs/proxy.mjs'], {
    env: {
      ...process.env,
      PORT: '18080',
      UPSTREAM_PORT: '18320',
      DATA_DIR: 'C:/Users/a/AppData/Local/Temp/test_sshd'
    }
  });

  await new Promise(r => setTimeout(r, 1000));

  const ingressPrefix = '/api/hassio_ingress/token_xyz';

  // Test 1: Ingress health
  const healthRes = await fetch('http://127.0.0.1:18080/healthz');
  const healthJson = await healthRes.json();
  assert.strictEqual(healthJson.status, 'healthy', 'Healthz returns healthy when upstream is active');

  // Test 2: Ingress path routing & cookie rewrite
  const accRes = await fetch('http://127.0.0.1:18080' + ingressPrefix + '/api/accounts', {
    headers: { 'X-Ingress-Path': ingressPrefix }
  });
  const accJson = await accRes.json();
  assert.strictEqual(accJson.count, 1, 'Accounts fetched via Ingress');
  const setCookie = accRes.headers.get('set-cookie');
  assert(setCookie.includes('Path=' + ingressPrefix + '/'), 'Cookie path rewritten to ingress prefix');

  // Test 3: Redirect Location rewrite
  const redirRes = await fetch('http://127.0.0.1:18080' + ingressPrefix + '/redirect', {
    redirect: 'manual',
    headers: { 'X-Ingress-Path': ingressPrefix }
  });
  const loc = redirRes.headers.get('location');
  assert.strictEqual(loc, ingressPrefix + '/api/accounts', 'Redirect location rewritten to ingress prefix');

  // Test 4: HTML body link and script rewrite
  const pageRes = await fetch('http://127.0.0.1:18080' + ingressPrefix + '/page', {
    headers: { 'X-Ingress-Path': ingressPrefix }
  });
  const pageHtml = await pageRes.text();
  assert(pageHtml.includes('src="' + ingressPrefix + '/app.js"'), 'Script src rewritten');
  assert(pageHtml.includes('href="' + ingressPrefix + '/api/health"'), 'Link href rewritten');

  // Test 5: Concurrency check (50 concurrent requests)
  console.log('Sending 50 concurrent requests through proxy...');
  const promises = [];
  for (let i = 0; i < 50; i++) {
    promises.push(fetch('http://127.0.0.1:18080' + ingressPrefix + '/api/accounts', {
      headers: { 'X-Ingress-Path': ingressPrefix }
    }).then(r => r.json()));
  }
  const results = await Promise.all(promises);
  assert.strictEqual(results.length, 50, 'All 50 concurrent requests succeeded');

  console.log('[PASS] All HAOS Add-on Ingress proxy tests passed.');
  proxyProc.kill();
  upstream.close();
  process.exit(0);
});
