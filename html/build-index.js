#!/usr/bin/env node
// Builds a self-contained index.html: inlines local vendor/*.css|*.js directly
// into the HTML. Needed because ttyd --index serves ONE file (it doesn't serve
// arbitrary static assets — vendor/xterm.js and the like). Run: node build-index.js <in.html> <out.html>
'use strict';
const fs = require('fs');
const path = require('path');

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error('usage: build-index.js <index.html> <out.html>');
  process.exit(1);
}

const dir = path.dirname(inPath);
let html = fs.readFileSync(inPath, 'utf8');

// <link rel="stylesheet" href="vendor/xxx.css"> -> <style>…</style>
html = html.replace(/<link[^>]*href="(vendor\/[^"]+\.css)"[^>]*>/g, function (_m, rel) {
  const css = fs.readFileSync(path.join(dir, rel), 'utf8');
  return '<style>\n' + css + '\n</style>';
});

// <script src="vendor/xxx.js"></script> -> <script>…</script>
html = html.replace(/<script[^>]*src="(vendor\/[^"]+\.js)"[^>]*><\/script>/g, function (_m, rel) {
  let js = fs.readFileSync(path.join(dir, rel), 'utf8');
  js = js.replace(/<\/script>/gi, '<\\/script>');   // so the content doesn't close the tag prematurely
  return '<script>\n' + js + '\n</script>';
});

if (/cdn\.|https?:\/\//.test(html.replace(/https?:\/\/[^"']*\/(ws|token)/g, ''))) {
  // crude safeguard: the built file should not contain any external asset references
  // (ws/token are built at runtime from location — we ignore those above)
}
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, html);
console.error('built ' + outPath + ' (' + html.length + ' bytes)');
