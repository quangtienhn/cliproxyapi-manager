import fs from 'node:fs';
import YAML from 'yaml';

export function validateCLIProxyAPIConfig(content) {
  const document = YAML.parseDocument(content, { uniqueKeys: true });
  if (document.errors.length) throw new Error('YAML syntax is invalid');
  const config = document.toJS();
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw new Error('top-level YAML value must be a mapping');
  if (!Object.hasOwn(config, 'port') || !Number.isInteger(config.port) || config.port < 1 || config.port > 65535) {
    throw new Error('required top-level port is missing or invalid');
  }
  for (const section of ['management', 'remote-management']) {
    if (section in config && (!config[section] || typeof config[section] !== 'object' || Array.isArray(config[section]))) {
      throw new Error(`${section} section is invalid`);
    }
  }
  if (config.management && 'allow-remote' in config.management && typeof config.management['allow-remote'] !== 'boolean') {
    throw new Error('management.allow-remote must be boolean');
  }
  return config;
}

if (process.argv[1]?.endsWith('validate_yaml.js')) {
  try { validateCLIProxyAPIConfig(fs.readFileSync(process.argv[2], 'utf8')); console.log('[OK] YAML configuration is valid'); }
  catch (error) { console.error(`[ERROR] YAML validation failed: ${error.message}`); process.exit(1); }
}
