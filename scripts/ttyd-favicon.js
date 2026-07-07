// Replaces the favicon in ttyd's native index.html with "Claude in a box" (SVG).
// Runs at image build time: reads the index.html fetched from ttyd, replaces
// <link rel="icon"> with our SVG data URI and writes the finished index.html alongside.
// Fails if the link isn't found — that means ttyd's format has changed and needs fixing.
const fs = require('fs');

const SRC = '/tmp/ttyd-index.html';
const SVG = '/opt/ttyd/box.svg';
const OUT = '/opt/ttyd/index.html';

const html = fs.readFileSync(SRC, 'utf8');
const svg = fs.readFileSync(SVG, 'utf8').trim();
const uri = 'data:image/svg+xml,' + encodeURIComponent(svg);
const link = '<link rel="icon" type="image/svg+xml" href="' + uri + '">';

const iconRe = /<link[^>]*rel=["']icon["'][^>]*>/i;
let out;
if (iconRe.test(html)) {
  out = html.replace(iconRe, link);
} else {
  out = html.replace(/<\/head>/i, link + '</head>');
}

if (out === html) {
  console.error('ttyd-favicon: could not find <link rel="icon"> or <head> — ttyd format changed');
  process.exit(1);
}

fs.writeFileSync(OUT, out);
console.log('ttyd-favicon: favicon replaced ->', OUT);
