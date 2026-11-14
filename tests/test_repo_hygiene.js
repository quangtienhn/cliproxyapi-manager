#!/usr/bin/env node
// ==============================================================================
// Repository hygiene checks
// ------------------------------------------------------------------------------
// Validates public-release invariants that are easy to break by hand:
//   - icon/logo dimensions and PNG signature
//   - Home Assistant add-on repository metadata and option schema
//   - version consistency between add-on, changelog, and bundle
//   - embedded bundle checksum and runtime-only contents
//   - no private development IPs/hostnames or committed secrets
//   - relative documentation links resolve
//   - no leftover temporary test scripts
// ==============================================================================
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
let pass = 0;
let fail = 0;

function ok(name, detail = '') {
  console.log(`  [PASS] ${name}${detail ? ` (${detail})` : ''}`);
  pass++;
}
function bad(name, detail = '') {
  console.log(`  [FAIL] ${name}${detail ? `: ${detail}` : ''}`);
  fail++;
}
function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}
function exists(rel) {
  return fs.existsSync(path.join(root, rel));
}

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === '.git' || entry.name === 'node_modules') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

console.log('=== Repository hygiene ===');

// --- Icon / logo -------------------------------------------------------------
function pngInfo(rel) {
  const b = fs.readFileSync(path.join(root, rel));
  if (b.length < 24) return null;
  const signature = b.subarray(0, 8).toString('hex');
  if (signature !== '89504e470d0a1a0a') return null;
  return { width: b.readUInt32BE(16), height: b.readUInt32BE(20), length: b.length };
}

for (const [rel, size] of [['haos-addon/icon.png', 256], ['haos-addon/logo.png', 512]]) {
  const info = pngInfo(rel);
  if (!info) bad(`${rel} is a valid PNG`);
  else if (info.width === size && info.height === size) ok(`${rel} is ${size}x${size}`);
  else bad(`${rel} dimensions`, `${info.width}x${info.height}, expected ${size}x${size}`);
}

if (exists('assets/generate-icon.py')) ok('icon generator is committed');
else bad('icon generator is committed');

// --- Add-on metadata ---------------------------------------------------------
const addonConfig = read('haos-addon/config.yaml');
const requiredAddonKeys = [
  'name', 'version', 'slug', 'description', 'arch', 'startup', 'boot',
  'ingress', 'ingress_port', 'ingress_entry', 'panel_title', 'options', 'schema'
];
for (const key of requiredAddonKeys) {
  if (new RegExp(`^${key}:`, 'm').test(addonConfig)) ok(`add-on config has ${key}`);
  else bad(`add-on config has ${key}`);
}
if (/^ports:/m.test(addonConfig)) bad('add-on must not publish host ports');
else ok('add-on publishes no host ports');
if (/^backup:\s*cold$/m.test(addonConfig)) ok('add-on uses cold backups');
else bad('add-on uses cold backups');
if (/^\s+- amd64$/m.test(addonConfig) && /^\s+- aarch64$/m.test(addonConfig)) {
  ok('add-on supports amd64 and aarch64');
} else {
  bad('add-on architectures');
}

function indentedKeys(text, section) {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((l) => l === `${section}:`);
  if (start === -1) return [];
  const keys = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\S/.test(lines[i])) break;
    const m = lines[i].match(/^ {2}([A-Za-z0-9_]+):/);
    if (m) keys.push(m[1]);
  }
  return keys;
}
const optionKeys = indentedKeys(addonConfig, 'options');
const schemaKeys = indentedKeys(addonConfig, 'schema');
if (optionKeys.length > 0 && optionKeys.join(',') === schemaKeys.join(',')) {
  ok('add-on options and schema match', optionKeys.join(','));
} else {
  bad('add-on options and schema match', `options=${optionKeys.join(',')} schema=${schemaKeys.join(',')}`);
}

const repositoryYaml = read('repository.yaml');
if (/^name:/m.test(repositoryYaml) && /^url:/m.test(repositoryYaml) && /^maintainer:/m.test(repositoryYaml)) {
  ok('repository.yaml has name, url, and maintainer');
} else {
  bad('repository.yaml metadata');
}

for (const rel of ['haos-addon/Dockerfile', 'haos-addon/build.yaml', 'haos-addon/DOCS.md', 'haos-addon/translations/en.yaml']) {
  if (exists(rel)) ok(`${rel} exists`);
  else bad(`${rel} exists`);
}
const dockerfile = read('haos-addon/Dockerfile');
for (const file of ['run.sh', 'proxy.mjs', 'hostkey.mjs']) {
  if (dockerfile.includes(`rootfs/${file}`)) ok(`Dockerfile copies ${file}`);
  else bad(`Dockerfile copies ${file}`);
}

// --- Version consistency -----------------------------------------------------
const addonVersion = (addonConfig.match(/^version:\s*"?([0-9.]+)"?/m) || [])[1] || '';
const changelogVersion = (read('CHANGELOG.md').match(/^## \[([0-9.]+)\]/m) || [])[1] || '';
const addonChangelogVersion = (read('haos-addon/CHANGELOG.md').match(/^## ([0-9.]+)/m) || [])[1] || '';
const bundleName = `cliproxyapi-account-manager-v${addonVersion}.tar.gz`;
if (addonVersion && addonVersion === changelogVersion) ok(`root changelog matches add-on ${addonVersion}`);
else bad('root changelog version', `add-on=${addonVersion} changelog=${changelogVersion}`);
if (addonVersion && addonVersion === addonChangelogVersion) ok('add-on changelog matches');
else bad('add-on changelog version', `add-on=${addonVersion} changelog=${addonChangelogVersion}`);
if (exists(`server-installer/embedded/${bundleName}`)) ok(`bundle ${bundleName} exists`);
else bad(`bundle ${bundleName} exists`);
if (exists(`server-installer/embedded/SHA256SUMS-v${addonVersion}.txt`)) ok('bundle checksum file exists');
else bad('bundle checksum file exists');

// --- Bundle checksum and contents -------------------------------------------
const bundlePath = path.join(root, 'server-installer', 'embedded', bundleName);
const sumsPath = path.join(root, 'server-installer', 'embedded', `SHA256SUMS-v${addonVersion}.txt`);
if (fs.existsSync(bundlePath) && fs.existsSync(sumsPath)) {
  const expected = (fs.readFileSync(sumsPath, 'utf8').match(/^([a-f0-9]{64})/m) || [])[1];
  const actual = crypto.createHash('sha256').update(fs.readFileSync(bundlePath)).digest('hex');
  if (expected === actual) ok('embedded bundle checksum matches');
  else bad('embedded bundle checksum matches', `${actual} != ${expected}`);

  const list = spawnSync('tar', ['-tzf', bundleName], {
    cwd: path.join(root, 'server-installer', 'embedded'),
    encoding: 'utf8'
  });
  if (list.status === 0) {
    const entries = list.stdout.split(/\r?\n/).filter(Boolean);
    const required = ['src/server.js', 'public/index.html', 'package.json', 'LICENSE'];
    for (const rel of required) {
      if (entries.some((e) => e.replace(/^\.\//, '') === rel)) ok(`bundle contains ${rel}`);
      else bad(`bundle contains ${rel}`);
    }
    const forbidden = entries.filter((e) =>
      /(^|\/)(deploy|docs|tests)\//.test(e) ||
      /(^|\/)(README|CHANGELOG)\.md$/.test(e) ||
      /(^|\/)\.env\.example$/.test(e)
    );
    if (forbidden.length === 0) ok('bundle is runtime-only');
    else bad('bundle is runtime-only', forbidden.slice(0, 5).join(', '));
  } else {
    bad('bundle can be listed', list.stderr?.toString().trim());
  }
}

// --- Private data and secrets ------------------------------------------------
const privatePatterns = [
  [/\b192\.168\.\d{1,3}\.\d{1,3}\b/, 'private 192.168/16 address'],
  [/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, 'private 10/8 address'],
  [/\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/, 'private 172.16/12 address'],
  [/\bTX3\b/, 'legacy private hostname']
];
const secretPatterns = [
  [/-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----/, 'private key block'],
  [/\bgh[pousr]_[A-Za-z0-9]{20,}\b/, 'GitHub token'],
  [/\bAKIA[0-9A-Z]{16}\b/, 'AWS access key'],
  [/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, 'Slack token']
];

const files = walk(root);
for (const [re, label] of privatePatterns) {
  const hits = [];
  for (const file of files) {
    if (/\.(png|gz|sha256)$/.test(file)) continue;
    const text = fs.readFileSync(file, 'utf8');
    if (re.test(text)) hits.push(path.relative(root, file));
  }
  if (hits.length === 0) ok(`no ${label} in current tree`);
  else bad(`no ${label} in current tree`, hits.join(', '));
}
for (const [re, label] of secretPatterns) {
  const hits = [];
  for (const file of files) {
    if (/\.(png|gz|sha256)$/.test(file)) continue;
    const text = fs.readFileSync(file, 'utf8');
    if (re.test(text)) hits.push(path.relative(root, file));
  }
  if (hits.length === 0) ok(`no ${label} in current tree`);
  else bad(`no ${label} in current tree`, hits.join(', '));
}

const tmpFiles = files.filter((f) => path.basename(f).startsWith('_tmp_'));
if (tmpFiles.length === 0) ok('no temporary test scripts');
else bad('no temporary test scripts', tmpFiles.map((f) => path.relative(root, f)).join(', '));

// --- Shell hygiene -----------------------------------------------------------
const shellFiles = files.filter((f) => f.endsWith('.sh') || path.basename(f) === 'cliproxy-manager');
const crlf = shellFiles.filter((f) => fs.readFileSync(f, 'utf8').includes('\r\n'));
if (crlf.length === 0) ok('shell scripts use LF line endings');
else bad('shell scripts use LF line endings', crlf.map((f) => path.relative(root, f)).join(', '));

const noShebang = shellFiles.filter((f) => !fs.readFileSync(f, 'utf8').startsWith('#!'));
if (noShebang.length === 0) ok('shell scripts have shebangs');
else bad('shell scripts have shebangs', noShebang.map((f) => path.relative(root, f)).join(', '));

// --- Relative documentation links -------------------------------------------
const markdownFiles = files.filter((f) => f.endsWith('.md'));
const broken = [];
let linkCount = 0;
for (const file of markdownFiles) {
  const text = fs.readFileSync(file, 'utf8');
  for (const match of text.matchAll(/\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
    const raw = match[1];
    if (/^(?:https?:|mailto:|#)/i.test(raw)) continue;
    const target = raw.split('#')[0];
    if (!target) continue;
    linkCount++;
    const resolved = path.resolve(path.dirname(file), decodeURIComponent(target));
    if (!fs.existsSync(resolved)) broken.push(`${path.relative(root, file)} -> ${raw}`);
  }
}
if (broken.length === 0) ok(`${linkCount} relative documentation links resolve`);
else bad('relative documentation links resolve', broken.slice(0, 10).join('; '));

// --- Required public files ---------------------------------------------------
for (const rel of [
  'README.md', 'SECURITY.md', 'CHANGELOG.md', 'LICENSE', 'CONTRIBUTING.md',
  'CODE_OF_CONDUCT.md', 'THIRD-PARTY-NOTICES.md', 'repository.yaml',
  'docs/INSTALLATION.md', 'docs/OPERATIONS.md', 'docs/ARCHITECTURE.md',
  'docs/UPGRADING.md', 'docs/TROUBLESHOOTING.md', 'docs/HAOS-ADDON.md',
  'docs/RELEASE-PROCESS.md'
]) {
  if (exists(rel)) ok(`${rel} exists`);
  else bad(`${rel} exists`);
}

console.log('--------------------------------------------------------');
console.log(`Results: ${pass} passed, ${fail} failed.`);
process.exit(fail === 0 ? 0 : 1);
