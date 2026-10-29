const fs = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const root = process.argv[2];
const files = [];
(function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name.startsWith('.git')) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (/\.(ya?ml)$/.test(e.name)) files.push(p);
  }
})(root);

let bad = 0;
for (const f of files) {
  const txt = fs.readFileSync(f, 'utf8');
  try {
    const docs = yaml.loadAll(txt);
    console.log('OK   ' + path.relative(root, f) + '  (docs: ' + (Array.isArray(docs) ? docs.length : 1) + ')');
  } catch (err) {
    bad++;
    console.log('FAIL ' + path.relative(root, f) + '  -> ' + String(err.message).split('\n')[0]);
  }
}
console.log('\nChecked: ' + files.length + ', failed: ' + bad);
process.exit(bad ? 1 : 0);
