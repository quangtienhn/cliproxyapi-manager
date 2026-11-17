import test from 'node:test';
import assert from 'node:assert/strict';
import { validateCLIProxyAPIConfig } from '../src/validate_yaml.js';

test('CLIProxyAPI YAML validation accepts valid configuration', () => {
  assert.equal(validateCLIProxyAPIConfig('port: 8317\nmanagement:\n  allow-remote: false\n').port, 8317);
});

test('CLIProxyAPI YAML validation rejects malformed YAML containing port', () => {
  assert.throws(() => validateCLIProxyAPIConfig('port: 8317\nmanagement: [broken\n'));
});

test('CLIProxyAPI YAML validation rejects missing required top-level configuration', () => {
  assert.throws(() => validateCLIProxyAPIConfig('host: 127.0.0.1\n'));
});

test('CLIProxyAPI YAML validation rejects invalid management section', () => {
  assert.throws(() => validateCLIProxyAPIConfig('port: 8317\nmanagement: enabled\n'));
  assert.throws(() => validateCLIProxyAPIConfig('port: 8317\nmanagement:\n  allow-remote: yes\n'));
});
