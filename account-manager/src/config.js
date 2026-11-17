import fs from 'node:fs';
import path from 'node:path';

function parseEnvValue(value) {
  const text = value.trim();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    return JSON.parse(text);
  }
  if (text.length >= 2 && text.startsWith("'") && text.endsWith("'")) {
    return text.slice(1, -1).replaceAll("''", "'");
  }
  return text;
}

export function loadConfig(envFile = '.env') {
  const env = { ...process.env };
  if (fs.existsSync(envFile)) {
    const lines = fs.readFileSync(envFile, 'utf8').split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx !== -1) {
        const key = trimmed.slice(0, eqIdx).trim();
        const val = parseEnvValue(trimmed.slice(eqIdx + 1));
        if (env[key] === undefined) {
          env[key] = val;
        }
      }
    }
  }

  return {
    port: parseInt(env.PORT || '8320', 10),
    host: env.HOST || '0.0.0.0',
    nodeEnv: env.NODE_ENV || 'production',
    adminUsername: env.ADMIN_USERNAME || 'admin',
    adminPasswordHash: env.ADMIN_PASSWORD_HASH || '',
    sessionTtlMinutes: parseInt(env.SESSION_TTL_MINUTES || '120', 10),
    cookieSecure: env.COOKIE_SECURE === 'true',
    cliProxyApiUrl: (env.CLIPROXYAPI_URL || 'http://127.0.0.1:8317').replace(/\/+$/, ''),
    cliProxyApiManagementKey: env.CLIPROXYAPI_MANAGEMENT_KEY || '',
    authDir: env.AUTH_DIR || '/var/lib/cliproxyapi/auths',
    cliProxyApiBin: env.CLIPROXYAPI_BIN || '/usr/local/bin/cliproxyapi',
    cliProxyApiService: env.CLIPROXYAPI_SERVICE || 'cliproxyapi',
    dataDir: env.DATA_DIR || '/var/lib/cliproxyapi-account-manager',
    rateLimitLoginMax: parseInt(env.RATE_LIMIT_LOGIN_MAX || '5', 10),
    rateLimitLoginWindowSec: parseInt(env.RATE_LIMIT_LOGIN_WINDOW_SEC || '60', 10),
    auditLogPath: env.AUDIT_LOG_PATH || path.join(process.cwd(), 'audit.log')
  };
}
