import test from 'node:test';
import assert from 'node:assert/strict';
import { hashPassword, verifyPassword, SessionManager, RateLimiter } from '../src/auth.js';

test('Auth: Password hashing and verification using scrypt', async () => {
  const password = 'SuperSecretMasterPassword123!';
  const hash = await hashPassword(password);

  assert.ok(hash.startsWith('scrypt:'), 'Hash should start with scrypt:');
  const valid = await verifyPassword(password, hash);
  assert.equal(valid, true, 'Correct password must verify');

  const invalid = await verifyPassword('WrongPassword', hash);
  assert.equal(invalid, false, 'Wrong password must fail verification');
});

test('Auth: SessionManager lifecycle & CSRF validation', () => {
  const sessionManager = new SessionManager(60); // 60 minutes
  const session = sessionManager.createSession('admin');

  assert.ok(session.sessionToken, 'Session token should be generated');
  assert.ok(session.csrfToken, 'CSRF token should be generated');

  const retrieved = sessionManager.getSession(session.sessionToken);
  assert.ok(retrieved, 'Session should be retrievable');
  assert.equal(retrieved.username, 'admin');

  // Validate CSRF
  assert.equal(sessionManager.validateCsrf(session.sessionToken, session.csrfToken), true);
  assert.equal(sessionManager.validateCsrf(session.sessionToken, 'invalid-csrf-token'), false);
  assert.equal(sessionManager.validateCsrf('non-existent-session', session.csrfToken), false);

  // Destroy session
  sessionManager.destroySession(session.sessionToken);
  assert.equal(sessionManager.getSession(session.sessionToken), null);
});

test('Auth: RateLimiter limits excessive failed attempts', () => {
  const rateLimiter = new RateLimiter(3, 60); // 3 attempts per 60 sec
  const testIp = '203.0.113.50';

  assert.equal(rateLimiter.isAllowed(testIp), true);

  rateLimiter.recordAttempt(testIp, false);
  assert.equal(rateLimiter.isAllowed(testIp), true);

  rateLimiter.recordAttempt(testIp, false);
  assert.equal(rateLimiter.isAllowed(testIp), true);

  rateLimiter.recordAttempt(testIp, false);
  assert.equal(rateLimiter.isAllowed(testIp), false, 'Should be rate limited after 3 failed attempts');

  // Successful attempt resets record
  rateLimiter.recordAttempt(testIp, true);
  assert.equal(rateLimiter.isAllowed(testIp), true);
});
