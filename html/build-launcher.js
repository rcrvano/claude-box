#!/usr/bin/env node
// Builds a self-contained launcher.html: inlines local fonts/*.woff2 referenced from
// @font-face rules directly into the HTML as base64 data: URLs. Needed because the web
// sidecar serves the launcher as ONE file (it doesn't serve arbitrary static assets —
// any other path falls through to the ttyd proxy). No CDN: same self-contained contract
// as build-index.js. Run: node build-launcher.js <in.html> <out.html>
'use strict';
const fs = require('fs');
const path = require('path');
const { assertSelfContained } = require('./self-contained.js');

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error('usage: build-launcher.js <launcher.html> <out.html>');
  process.exit(1);
}

const dir = path.dirname(inPath);
let html = fs.readFileSync(inPath, 'utf8');

// url(fonts/<name>.woff2) -> url(data:font/woff2;base64,<b64>)
// (inside @font-face src). Quotes around the path are optional.
html = html.replace(/url\(\s*["']?(fonts\/[^"')]+\.woff2)["']?\s*\)/g, function (_m, rel) {
  const b64 = fs.readFileSync(path.join(dir, rel)).toString('base64');
  return 'url(data:font/woff2;base64,' + b64 + ')';
});

assertSelfContained('build-launcher', html, [
  ['uninlined fonts/ reference', /url\(\s*["']?fonts\//],
]);

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, html);
console.error('built ' + outPath + ' (' + html.length + ' bytes)');
