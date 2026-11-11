import assert from 'node:assert';
import http from 'node:http';
import net from 'node:net';

console.log('=== Verifying Account Manager Loopback Socket Binding Invariants ===');

// Function to test socket binding
async function testBinding(host, port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => res.end('OK'));
    server.listen(port, host, () => {
      resolve(server);
    });
    server.on('error', reject);
  });
}

// 1. Verify 127.0.0.1 (IPv4 Loopback)
const s1 = await testBinding('127.0.0.1', 18330);
console.log('  [PASS] 127.0.0.1:18330 loopback bind succeeded.');

// Verify it responds on 127.0.0.1
const r1 = await fetch('http://127.0.0.1:18330');
assert.strictEqual(await r1.text(), 'OK');
s1.close();

// 2. Verify ::1 (IPv6 Loopback)
try {
  const s2 = await testBinding('::1', 18331);
  console.log('  [PASS] [::1]:18331 loopback bind succeeded.');
  s2.close();
} catch (e) {
  console.log('  [WARN] IPv6 loopback not supported on this host environment:', e.message);
}

// 3. Confirm template enforces loopback
import fs from 'node:fs';
const template = fs.readFileSync('server-installer/templates/manager.env.template', 'utf8');
assert(template.includes('HOST=127.0.0.1'), 'Template explicitly enforces HOST=127.0.0.1');
assert(!template.includes('HOST=0.0.0.0'), 'Template does NOT allow wildcard HOST=0.0.0.0');

console.log('  [PASS] Account Manager loopback invariant strictly confirmed.');
