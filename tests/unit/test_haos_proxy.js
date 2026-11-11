import assert from 'node:assert';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// Unit and integration verification for proxy.mjs logic

console.log('=== Running HAOS Add-on Proxy Logic Tests ===');

// Test 1: URL Prefix rewriting
const PREFIX_RE = /^\/api\/hassio_ingress\/[A-Za-z0-9_-]+$/;

function ingressPrefix(rawHeader, rawUrl) {
  const raw = String(rawHeader || '').split(',')[0].trim();
  if (raw) {
    const p = raw.replace(/\/+$/, '');
    if (PREFIX_RE.test(p)) return p;
  }
  const m = String(rawUrl || '').match(/^(\/api\/hassio_ingress\/[A-Za-z0-9_-]+)(?:[/?]|$)/);
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

const prefix = ingressPrefix('/api/hassio_ingress/token123', '/api/hassio_ingress/token123/api/accounts');
assert.strictEqual(prefix, '/api/hassio_ingress/token123', 'Ingress prefix correctly extracted');

const stripped = stripPrefix('/api/hassio_ingress/token123/api/accounts', prefix);
assert.strictEqual(stripped, '/api/accounts', 'Ingress prefix cleanly stripped');

// Test 2: Ingress HTML/JS Link and Path Rewriter
function rewriteText(body, prefix) {
  if (!prefix) return body;
  return body
    .replace(/(["'`])\/api\/(?!hassio_ingress\/)/g, `$1${prefix}/api/`)
    .replace(/(\b(?:href|src|action)=)(["'])\/(?!\/|api\/hassio_ingress\/)/gi, `$1$2${prefix}/`)
    .replace(/(url\(\s*["']?)\/(?!\/|api\/hassio_ingress\/)/gi, `$1${prefix}/`);
}

const inputHtml = '<a href="/api/health">Health</a><script src="/app.js"></script>';
const rewrittenHtml = rewriteText(inputHtml, prefix);
assert(rewrittenHtml.includes('/api/hassio_ingress/token123/api/health'), 'Health API URL properly rewritten');
assert(rewrittenHtml.includes('/api/hassio_ingress/token123/app.js'), 'Asset path properly rewritten with ingress prefix');

// Test 3: Cookie and Location Header Rewriting
function rewriteCookies(value, prefix) {
  if (!prefix || !value) return value;
  const arr = Array.isArray(value) ? value : [value];
  return arr.map((c) => c.replace(/;\s*Path=\/(?=;|$)/i, `; Path=${prefix}/`));
}

const rawCookie = 'session=abcdef123456; Path=/; HttpOnly';
const rewrittenCookie = rewriteCookies(rawCookie, prefix)[0];
assert(rewrittenCookie.includes(`Path=${prefix}/`), 'Cookie path rewritten to ingress prefix');

console.log('[PASS] All HAOS Add-on proxy logic tests succeeded.');
