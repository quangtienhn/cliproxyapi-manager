import fs from 'node:fs';

export class AuditLogger {
  constructor(logFilePath) {
    this.logFilePath = logFilePath;
  }

  // Redact any potential credentials, tokens, passwords from values
  sanitize(obj) {
    if (obj === null || obj === undefined) return obj;
    if (typeof obj === 'string') {
      // Redact Bearer tokens, passwords, secrets
      return obj
        .replace(/Bearer\s+[A-Za-z0-9\-._~+/]+=*/gi, 'Bearer [REDACTED]')
        .replace(/(password|secret|token|key|access_token|refresh_token)\s*[:=]\s*["']?[^"'\s,]+["']?/gi, '$1=[REDACTED]');
    }
    if (typeof obj !== 'object') return obj;

    if (Array.isArray(obj)) {
      return obj.map(item => this.sanitize(item));
    }

    const cleaned = {};
    const sensitiveKeys = new Set([
      'password', 'password_hash', 'secret', 'management_key',
      'access_token', 'refresh_token', 'id_token', 'api_key', 'token'
    ]);

    for (const [k, v] of Object.entries(obj)) {
      if (sensitiveKeys.has(k.toLowerCase())) {
        cleaned[k] = '[REDACTED]';
      } else {
        cleaned[k] = this.sanitize(v);
      }
    }
    return cleaned;
  }

  log(event, details = {}, ip = '127.0.0.1', user = 'system') {
    const entry = {
      timestamp: new Date().toISOString(),
      event,
      user,
      ip,
      details: this.sanitize(details)
    };

    const line = JSON.stringify(entry) + '\n';
    try {
      if (this.logFilePath) {
        fs.appendFileSync(this.logFilePath, line, 'utf8');
      }
    } catch (err) {
      console.error('AuditLogger error writing file:', err.message);
    }
    console.log(`[AUDIT] ${entry.timestamp} | ${event} | User:${user} | IP:${ip}`);
  }
}
