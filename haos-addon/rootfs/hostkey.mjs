#!/usr/bin/env node
// Validates a user-supplied SSH host public key and writes a pinned
// known_hosts file for the HAOS tunnel add-on.
//
// Usage: node hostkey.mjs <host> <port> <outfile>   (key line(s) on stdin)
// Exit codes: 0 success, 2 invalid input, 1 write failure.

import fs from 'node:fs';

const KEY_TYPES = new Set([
  'ssh-ed25519',
  'ssh-rsa',
  'ecdsa-sha2-nistp256',
  'ecdsa-sha2-nistp384',
  'ecdsa-sha2-nistp521',
  'sk-ssh-ed25519@openssh.com',
  'sk-ecdsa-sha2-nistp256@openssh.com'
]);

function fail(message, code = 2) {
  console.error(`[hostkey] ${message}`);
  process.exit(code);
}

const [hostArg, portArg, outFile] = process.argv.slice(2);
const host = String(hostArg || '').trim();
const port = String(portArg || '22').trim();

if (!outFile) fail('missing output path');
if (!host) fail('missing server host');
if (!/^[0-9]{1,5}$/.test(port)) fail(`invalid SSH port: ${port}`);
const portNum = Number(port);
if (portNum < 1 || portNum > 65535) fail(`invalid SSH port: ${port}`);

// Host may be a DNS name, IPv4 literal, or IPv6 literal. Reject whitespace,
// hashes, slashes and shell metacharacters outright.
if (!/^[A-Za-z0-9._:\-\[\]]+$/.test(host) || host.startsWith('-')) {
  fail(`invalid server host: ${host}`);
}

const isIpv6 = host.includes(':');
const baseName = host.replace(/^\[|\]$/g, '');
const knownHostName = portNum === 22 && !isIpv6
  ? baseName
  : `[${baseName}]:${port}`;

const input = fs.readFileSync(0, 'utf8');
const output = [];

for (const rawLine of input.split(/\r?\n/)) {
  const line = rawLine.trim();
  if (!line || line.startsWith('#')) continue;

  let parts = line.split(/\s+/);
  // Accept lines that accidentally include a "host key" prefix.
  if (!KEY_TYPES.has(parts[0])) parts = parts.slice(1);
  if (parts.length < 2 || !KEY_TYPES.has(parts[0])) {
    fail('invalid host key type');
  }
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(parts[1]) || parts[1].length < 32) {
    fail('invalid host key encoding');
  }
  output.push(`${knownHostName} ${parts[0]} ${parts[1]}`);
}

if (output.length === 0) fail('no valid host key line supplied');

try {
  fs.writeFileSync(outFile, `${output.join('\n')}\n`, { mode: 0o600 });
} catch (error) {
  fail(`unable to write known_hosts: ${error.message}`, 1);
}
