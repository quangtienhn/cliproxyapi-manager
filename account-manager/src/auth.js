import crypto from 'node:crypto';

// Strong password hashing using scrypt
export async function hashPassword(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(16).toString('hex');
    crypto.scrypt(password, salt, 64, (err, derivedKey) => {
      if (err) return reject(err);
      resolve(`scrypt:${salt}:${derivedKey.toString('hex')}`);
    });
  });
}

export async function verifyPassword(password, storedHash) {
  if (!storedHash || !password) return false;
  const parts = storedHash.split(':');
  if (parts.length !== 3 || parts[0] !== 'scrypt') return false;

  const [, salt, originalHex] = parts;
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, 64, (err, derivedKey) => {
      if (err) return reject(err);
      const originalBuffer = Buffer.from(originalHex, 'hex');
      if (originalBuffer.length !== derivedKey.length) {
        return resolve(false);
      }
      resolve(crypto.timingSafeEqual(originalBuffer, derivedKey));
    });
  });
}

// In-memory session store with TTL and CSRF token
export class SessionManager {
  constructor(ttlMinutes = 120) {
    this.ttlMs = ttlMinutes * 60 * 1000;
    this.sessions = new Map();
  }

  createSession(username) {
    const sessionToken = crypto.randomBytes(32).toString('hex');
    const csrfToken = crypto.randomBytes(32).toString('hex');
    const now = Date.now();
    const expiresAt = now + this.ttlMs;

    this.sessions.set(sessionToken, {
      username,
      csrfToken,
      createdAt: now,
      expiresAt
    });

    return { sessionToken, csrfToken, expiresAt };
  }

  getSession(sessionToken) {
    if (!sessionToken) return null;
    const session = this.sessions.get(sessionToken);
    if (!session) return null;

    if (Date.now() > session.expiresAt) {
      this.sessions.delete(sessionToken);
      return null;
    }
    return session;
  }

  validateCsrf(sessionToken, receivedCsrf) {
    const session = this.getSession(sessionToken);
    if (!session) return false;
    if (!receivedCsrf || typeof receivedCsrf !== 'string') return false;
    const bufA = Buffer.from(session.csrfToken, 'utf8');
    const bufB = Buffer.from(receivedCsrf, 'utf8');
    if (bufA.length !== bufB.length) return false;
    return crypto.timingSafeEqual(bufA, bufB);
  }

  destroySession(sessionToken) {
    if (sessionToken) {
      this.sessions.delete(sessionToken);
    }
  }

  cleanupExpired() {
    const now = Date.now();
    for (const [token, session] of this.sessions.entries()) {
      if (now > session.expiresAt) {
        this.sessions.delete(token);
      }
    }
  }
}

// In-memory rate limiter for brute-force protection
export class RateLimiter {
  constructor(maxAttempts = 5, windowSec = 60) {
    this.maxAttempts = maxAttempts;
    this.windowMs = windowSec * 1000;
    this.attempts = new Map();
  }

  isAllowed(ip) {
    const now = Date.now();
    const record = this.attempts.get(ip);
    if (!record) return true;

    if (now - record.firstAttempt > this.windowMs) {
      this.attempts.delete(ip);
      return true;
    }

    return record.count < this.maxAttempts;
  }

  recordAttempt(ip, success = false) {
    if (success) {
      this.attempts.delete(ip);
      return;
    }

    const now = Date.now();
    const record = this.attempts.get(ip);
    if (!record || now - record.firstAttempt > this.windowMs) {
      this.attempts.set(ip, { count: 1, firstAttempt: now });
    } else {
      record.count += 1;
    }
  }
}
