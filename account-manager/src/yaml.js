// Safe pure-JS YAML parser and validator for CLIProxyAPI configuration
// Zero external dependencies

function parseSimpleYaml(content) {
  if (typeof content !== 'string') {
    throw new Error('YAML content must be a string');
  }

  const lines = content.split(/\r?\n/);
  const root = {};
  const stack = [{ indent: -1, obj: root }];

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const matchIndent = raw.match(/^(\s*)/);
    const indent = matchIndent ? matchIndent[1].length : 0;
    const trimmed = raw.trim();

    if (!trimmed || trimmed.startsWith('#')) continue;

    if (/^\s*\t/.test(raw)) {
      throw new Error(`YAML syntax error line ${i + 1}: Tabs not allowed`);
    }

    // Strip inline comments outside of quotes
    let clean = trimmed;
    let inQ = null;
    let commentIdx = -1;
    for (let c = 0; c < clean.length; c++) {
      if ((clean[c] === '"' || clean[c] === "'") && (c === 0 || clean[c - 1] !== '\\')) {
        if (!inQ) inQ = clean[c];
        else if (inQ === clean[c]) inQ = null;
      } else if (clean[c] === '#' && !inQ && c > 0 && /\s/.test(clean[c - 1])) {
        commentIdx = c;
        break;
      }
    }
    if (commentIdx !== -1) clean = clean.slice(0, commentIdx).trim();
    if (!clean) continue;

    while (stack.length > 1 && stack[stack.length - 1].indent >= indent) {
      stack.pop();
    }
    const current = stack[stack.length - 1].obj;

    const colon = clean.indexOf(':');
    if (colon === -1) throw new Error(`YAML syntax error line ${i + 1}: Missing colon in '${clean}'`);

    const key = clean.slice(0, colon).trim();
    const val = clean.slice(colon + 1).trim();

    if (!key) throw new Error(`YAML syntax error line ${i + 1}: Empty key`);

    if (val === '') {
      const newObj = {};
      current[key] = newObj;
      stack.push({ indent, obj: newObj });
    } else {
      let parsedVal = val;
      if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
        parsedVal = val.slice(1, -1)
          .replace(/\\"/g, '"')
          .replace(/\\\\/g, '\\')
          .replace(/\\n/g, '\n')
          .replace(/\\r/g, '\r')
          .replace(/\\t/g, '\t');
      } else if (val.startsWith("'") && val.endsWith("'") && val.length >= 2) {
        parsedVal = val.slice(1, -1).replace(/''/g, "'");
      } else if (val === 'true') parsedVal = true;
      else if (val === 'false') parsedVal = false;
      else if (/^-?[0-9]+$/.test(val)) parsedVal = parseInt(val, 10);
      current[key] = parsedVal;
    }
  }
  return root;
}

export function validateCLIProxyAPIYaml(yamlContent) {
  const doc = parseSimpleYaml(yamlContent);
  if (!doc || typeof doc !== 'object') {
    throw new Error('Config root must be a YAML mapping');
  }
  if (!('port' in doc)) {
    throw new Error("Missing required 'port' field in configuration");
  }
  const port = parseInt(doc.port, 10);
  if (isNaN(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid port value: ${doc.port}`);
  }
  if (doc.management && typeof doc.management !== 'object') {
    throw new Error("Invalid 'management' section structure");
  }
  if (doc['remote-management'] && typeof doc['remote-management'] !== 'object') {
    throw new Error("Invalid 'remote-management' section structure");
  }
  return doc;
}

// Standalone CLI validator support
if (process.argv[1] && process.argv[1].endsWith('yaml.js')) {
  const fs = await import('node:fs');
  const targetFile = process.argv[2];
  if (!targetFile) {
    console.error('Usage: node yaml.js <config.yaml>');
    process.exit(1);
  }
  try {
    const raw = fs.readFileSync(targetFile, 'utf8');
    validateCLIProxyAPIYaml(raw);
    console.log('[OK] YAML configuration is valid.');
    process.exit(0);
  } catch (err) {
    console.error(`[ERROR] YAML validation failed: ${err.message}`);
    process.exit(1);
  }
}
