import fs from 'node:fs';
import path from 'node:path';

// Mermaid needs a DOM-ish global before import
const { JSDOM } = await import('jsdom').catch(() => ({ JSDOM: null }));
if (JSDOM) {
  const dom = new JSDOM('<!DOCTYPE html><body></body>', { pretendToBeVisual: true });
  global.window = dom.window;
  global.document = dom.window.document;
  try { Object.defineProperty(global, "navigator", { value: dom.window.navigator, configurable: true }); } catch (e) {}
  global.DOMPurify = undefined;
}

const mermaid = (await import('mermaid')).default;
mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });

const root = process.argv[2];
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) { if (e.name !== 'node_modules' && e.name !== '.git') walk(p); }
    else if (e.name.endsWith('.md')) files.push(p);
  }
})(root);

let total = 0, failed = 0;
for (const f of files.sort()) {
  const src = fs.readFileSync(f, 'utf8');
  const blocks = [...src.matchAll(/```mermaid\r?\n([\s\S]*?)```/g)];
  let idx = 0;
  for (const m of blocks) {
    idx++; total++;
    const code = m[1];
    const kind = (code.trim().split(/\s+/)[0] || '?');
    const lineNo = src.slice(0, m.index).split('\n').length;
    try {
      await mermaid.parse(code);
      console.log(`  PASS  ${path.basename(f)}:${lineNo}  #${idx} ${kind}`);
    } catch (err) {
      failed++;
      const msg = String(err && err.message ? err.message : err).split('\n').slice(0, 4).join(' | ');
      console.log(`  FAIL  ${path.basename(f)}:${lineNo}  #${idx} ${kind}`);
      console.log(`        ${msg}`);
    }
  }
}
console.log(`\n${total - failed}/${total} diagrams parsed successfully`);
process.exit(failed ? 1 : 0);
