const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

// Match browser script boundaries: a literal closing script tag also ends a
// script inside a JS string. This catches injected markup in print templates.
const root = path.resolve(__dirname, '../..');
let checked = 0;
for (const file of fs.readdirSync(root).filter(f => f.endsWith('.html'))) {
  const html = fs.readFileSync(path.join(root, file), 'utf8');
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)) {
    const type = /\btype\s*=\s*["']([^"']+)["']/i.exec(m[1])?.[1];
    if (type && !/^(text|application)\/javascript$/i.test(type)) continue;
    const line = html.slice(0, m.index).split('\n').length;
    new vm.Script(m[2], { filename: `${file}:${line}` });
    checked++;
  }
  if (file === 'index.html') {
    assert.equal((html.match(/<script id="fm-v331-integration">/g) || []).length, 1,
      'Integration navigation must appear once, outside exported reports');
  }
}
console.log(`PASS: ${checked} inline scripts parse; integration navigation appears once`);
