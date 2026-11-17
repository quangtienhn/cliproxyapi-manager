import fs from 'node:fs';
import path from 'node:path';
import YAML from 'yaml';

function readManagementSecret(configPath) {
  const source = fs.readFileSync(configPath, 'utf8');
  const document = YAML.parseDocument(source, { uniqueKeys: true });
  if (document.errors.length) throw new Error('CLIProxyAPI YAML is invalid');
  const management = document.toJS().management;
  if (!management || typeof management !== 'object' || Array.isArray(management)) {
    throw new Error('management section is missing or invalid');
  }
  const secret = management['secret-key'];
  if (typeof secret !== 'string' || secret.length === 0) {
    throw new Error('management.secret-key is missing or empty');
  }
  return secret;
}

function parseEnvValue(value) {
  const text = value.trim();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    try { return JSON.parse(text); } catch { throw new Error('invalid double-quoted environment value'); }
  }
  if (text.length >= 2 && text.startsWith("'") && text.endsWith("'")) {
    return text.slice(1, -1).replaceAll("''", "'");
  }
  return text;
}

export function encodeEnvValue(value) {
  return JSON.stringify(value);
}

export function syncManagementKey(configPath, envPath) {
  if (fs.lstatSync(configPath).isSymbolicLink() || fs.lstatSync(envPath).isSymbolicLink() ||
      !fs.statSync(configPath).isFile() || !fs.statSync(envPath).isFile()) {
    throw new Error('configuration and environment paths must be regular files');
  }
  const secret = readManagementSecret(configPath);
  const original = fs.statSync(envPath);
  const lines = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
  const output = [];
  let found = false;
  for (const line of lines) {
    const match = line.match(/^\s*CLIPROXYAPI_MANAGEMENT_KEY\s*=(.*)$/);
    if (!match) { output.push(line); continue; }
    if (!found) {
      output.push(`CLIPROXYAPI_MANAGEMENT_KEY=${encodeEnvValue(secret)}`);
      found = true;
    }
  }
  if (!found) output.push(`CLIPROXYAPI_MANAGEMENT_KEY=${encodeEnvValue(secret)}`);

  const temp = path.join(path.dirname(envPath), `.${path.basename(envPath)}.tmp-${process.pid}-${Date.now()}`);
  try {
    fs.writeFileSync(temp, output.join('\n'), { mode: original.mode & 0o777 });
    fs.chownSync(temp, original.uid, original.gid);
    fs.chmodSync(temp, original.mode & 0o777);
    fs.renameSync(temp, envPath);
  } catch (error) {
    try { fs.unlinkSync(temp); } catch {}
    throw error;
  }
  return true;
}

if (process.argv[1] && process.argv[1].endsWith('sync_secret.js')) {
  try { syncManagementKey(process.argv[2], process.argv[3]); console.log('[SUCCESS] Management key synchronized'); }
  catch (error) { console.error(`[ERROR] ${error.message}`); process.exit(1); }
}
