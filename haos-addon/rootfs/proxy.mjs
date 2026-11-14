import http from 'node:http';
import fs from 'node:fs';

const PORT = Number(process.env.PORT || 8080);
const UPSTREAM_HOST = '127.0.0.1';
const UPSTREAM_PORT = Number(process.env.UPSTREAM_PORT || 18320);
const DATA_DIR = process.env.DATA_DIR || '/data';
const PREFIX_RE = /^\/api\/hassio_ingress\/[A-Za-z0-9_-]+$/;
const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade'
]);

function log(...args) {
  console.log(new Date().toISOString(), '[proxy]', ...args);
}

function readPubKey() {
  try {
    return fs.readFileSync(`${DATA_DIR}/id_ed25519.pub`, 'utf8').trim();
  } catch {
    return null;
  }
}

function readTarget() {
  try {
    const o = JSON.parse(fs.readFileSync(`${DATA_DIR}/options.json`, 'utf8'));
    const host = o.server_host || null;
    const user = o.server_user || 'amtunnel';
    const remoteHost = o.remote_host || '127.0.0.1';
    const remotePort = o.remote_port || 8320;
    return {
      host,
      user,
      remote: `${remoteHost}:${remotePort}`,
      configured: Boolean(String(o.host_key || '').trim())
    };
  } catch {
    return { configured: false };
  }
}

function ingressPrefix(req) {
  const raw = String(req.headers['x-ingress-path'] || '').split(',')[0].trim();
  if (raw) {
    const p = raw.replace(/\/+$/, '');
    if (PREFIX_RE.test(p)) return p;
  }
  const m = String(req.url || '').match(/^(\/api\/hassio_ingress\/[A-Za-z0-9_-]+)(?:[/?]|$)/);
  return m ? m[1] : '';
}

function stripPrefix(url, prefix) {
  if (!prefix) return url || '/';
  if (url === prefix) return '/';
  if (url.startsWith(prefix + '/') || url.startsWith(prefix + '?')) {
    return url.slice(prefix.length);
  }
  return url;
}

function normalizePath(url) {
  if (!url) return '/';
  let p = url;
  const abs = p.match(/^https?:\/\/[^/]+(\/.*)?$/i);
  if (abs) p = abs[1] || '/';
  if (!p.startsWith('/')) p = '/' + p;
  return p.replace(/^\/{2,}/, '/');
}

let healthCache = { at: 0, ok: false, checked: false };

function upstreamHealth() {
  const now = Date.now();
  if (healthCache.checked && now - healthCache.at < 2000) {
    return Promise.resolve(healthCache.ok);
  }
  return new Promise((resolve) => {
    const req = http.request({
      host: UPSTREAM_HOST,
      port: UPSTREAM_PORT,
      path: '/api/health',
      method: 'GET',
      timeout: 2500,
      agent: false,
      headers: { connection: 'close' }
    }, (res) => {
      res.resume();
      const ok = res.statusCode === 200;
      healthCache = { at: Date.now(), ok, checked: true };
      resolve(ok);
    });
    req.on('timeout', () => {
      req.destroy();
      healthCache = { at: Date.now(), ok: false, checked: true };
      resolve(false);
    });
    req.on('error', () => {
      healthCache = { at: Date.now(), ok: false, checked: true };
      resolve(false);
    });
    req.end();
  });
}

function rewriteText(body, prefix) {
  if (!prefix) return body;
  return body
    .replace(/(["'`])\/api\/(?!hassio_ingress\/)/g, `$1${prefix}/api/`)
    .replace(/(\b(?:href|src|action)=)(["'])\/(?!\/|api\/hassio_ingress\/)/gi, `$1$2${prefix}/`)
    .replace(/(url\(\s*["']?)\/(?!\/|api\/hassio_ingress\/)/gi, `$1${prefix}/`);
}

function rewriteCookies(value, prefix) {
  if (!prefix || !value) return value;
  const arr = Array.isArray(value) ? value : [value];
  return arr.map((c) => c.replace(/;\s*Path=\/(?=;|$)/i, `; Path=${prefix}/`));
}

function rewriteLocation(value, prefix) {
  if (!prefix || !value) return value;
  if (value.startsWith('/') && !value.startsWith('//')) return prefix + value;
  return value;
}

function escapeHtml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function sendDownPage(res, prefix, detail) {
  const target = readTarget();
  const pub = readPubKey();
  const body = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Account Manager - tunnel not connected</title>
<style>
body{font-family:system-ui,sans-serif;background:#0f1420;color:#e6e9ef;margin:0;padding:2rem}
main{max-width:760px;margin:0 auto}
h1{font-size:1.4rem;margin:0 0 .5rem}
p{line-height:1.6;color:#b9c2d0}
code,pre{background:#1a2233;color:#dbe4f0;border-radius:8px}
pre{padding:1rem;overflow:auto;font-size:.8rem;word-break:break-all;white-space:pre-wrap}
code{padding:.15rem .35rem}
ul{line-height:1.7;color:#b9c2d0}
</style></head><body><main>
<h1>SSH tunnel not connected</h1>
<p>The HAOS Ingress reverse proxy is running, but it cannot reach Account Manager on the server.
${target.host ? `Target: <code>${escapeHtml(target.user)}@${escapeHtml(target.host)}</code> &rarr; <code>${escapeHtml(target.remote)}</code>` : ''}</p>
${target.configured ? '' : '<p><strong>Option <code>host_key</code> is not set.</strong> Paste your server host key into the add-on configuration.</p>'}
<ul>
<li>Ensure the Linux server is reachable over SSH from Home Assistant OS.</li>
<li>Ensure the restricted tunnel user exists and accepts this public key.</li>
<li>Ensure the pinned host key matches the server.</li>
</ul>
<p>Public key of this add-on (add it to the tunnel user on your server):</p>
<pre>${escapeHtml(pub || '(not generated yet)')}</pre>
<p>Status: <code>${escapeHtml(detail || 'tunnel down')}</code></p>
</main></body></html>`;
  res.writeHead(502, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(body)
  });
  res.end(body);
}

function handleHealth(res) {
  upstreamHealth().then((ok) => {
    const target = readTarget();
    const payload = JSON.stringify({
      status: ok ? 'healthy' : 'degraded',
      tunnel: ok ? 'connected' : 'disconnected',
      configured: target.configured,
      target: target.host ? `${target.user}@${target.host}` : null,
      timestamp: new Date().toISOString()
    });
    res.writeHead(ok ? 200 : 503, {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store'
    });
    res.end(payload);
  });
}

function forward(req, res, prefix, targetPath) {
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (!HOP_BY_HOP.has(k.toLowerCase()) && k.toLowerCase() !== 'host') {
      headers[k] = v;
    }
  }
  headers['host'] = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`;
  headers['x-forwarded-host'] = req.headers.host || '';
  headers['x-forwarded-proto'] = 'http';
  if (prefix) headers['x-ingress-path'] = prefix;

  const upReq = http.request({
    host: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    path: targetPath,
    method: req.method,
    headers,
    agent: false
  }, (upRes) => {
    const statusCode = upRes.statusCode || 500;
    const respHeaders = {};
    for (const [k, v] of Object.entries(upRes.headers)) {
      if (!HOP_BY_HOP.has(k.toLowerCase())) {
        respHeaders[k] = v;
      }
    }

    if (respHeaders['set-cookie']) {
      respHeaders['set-cookie'] = rewriteCookies(respHeaders['set-cookie'], prefix);
    }
    if (respHeaders['location']) {
      respHeaders['location'] = rewriteLocation(respHeaders['location'], prefix);
    }

    const ctype = String(respHeaders['content-type'] || '').toLowerCase();
    const isText = ctype.includes('text/html') ||
                   ctype.includes('text/javascript') ||
                   ctype.includes('application/javascript') ||
                   ctype.includes('text/css') ||
                   ctype.includes('application/json');

    if (prefix && isText) {
      delete respHeaders['content-length'];
      const chunks = [];
      upRes.on('data', (c) => chunks.push(c));
      upRes.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        const rewritten = rewriteText(raw, prefix);
        respHeaders['content-length'] = Buffer.byteLength(rewritten);
        res.writeHead(statusCode, respHeaders);
        res.end(rewritten);
      });
    } else {
      res.writeHead(statusCode, respHeaders);
      upRes.pipe(res);
    }
  });

  upReq.on('error', (err) => {
    log('Upstream error:', err.message);
    sendDownPage(res, prefix, err.message);
  });

  req.pipe(upReq);
}

const server = http.createServer((req, res) => {
  const prefix = ingressPrefix(req);
  let stripped = stripPrefix(req.url, prefix);
  const normalized = normalizePath(stripped);

  if (normalized === '/healthz' || normalized === '/api/tunnel/health') {
    return handleHealth(res);
  }

  forward(req, res, prefix, normalized);
});

server.listen(PORT, '0.0.0.0', () => {
  log(`Ingress proxy listening on 0.0.0.0:${PORT}, upstream target 127.0.0.1:${UPSTREAM_PORT}`);
});
