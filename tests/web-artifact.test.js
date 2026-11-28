'use strict';
// The artifact panel: the MCP tool show_artifact (cb-mcp.js) and the sandboxed file route
// (web-artifact.js). Run: node --test tests/
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'cb-art-')));
const ws = path.join(tmp, 'workspace'), snaps = path.join(tmp, 'snaps');
fs.mkdirSync(path.join(ws, 's', '.artifacts'), { recursive: true });
process.env.HOME = path.join(tmp, 'home');
process.env.CB_ARTIFACT_DIR = snaps;
process.env.CB_ARTIFACT_ROOTS = ws;
process.env.CB_ARTIFACT_SERVE_ROOTS = ws;
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const mcp = require('../scripts/cb-mcp.js');
const art = require('../scripts/web-artifact.js');
const page = path.join(ws, 's', '.artifacts', 'pricing.html');

test('show_artifact snapshots the file; later versions keep earlier ones', () => {
  fs.writeFileSync(page, '<h1>v1</h1>');
  const r1 = mcp.showArtifact({ path: '.artifacts/pricing.html', title: ' Pricing  page ' }, path.join(ws, 's'));
  assert.strictEqual(r1.title, 'Pricing page');
  assert.strictEqual(r1.path, page);
  fs.writeFileSync(page, '<h1>v2</h1>');
  const r2 = mcp.showArtifact({ path: page }, '/');
  assert.notStrictEqual(r1.snapshot, r2.snapshot);
  assert.strictEqual(fs.readFileSync(r1.snapshot, 'utf8'), '<h1>v1</h1>');
  assert.strictEqual(fs.readFileSync(r2.snapshot, 'utf8'), '<h1>v2</h1>');
  assert.strictEqual(r2.title, 'pricing.html');
});

test('show_artifact refuses what it should not show', () => {
  assert.throws(() => mcp.showArtifact({ path: path.join(ws, 'nope.html') }), /not found/);
  fs.writeFileSync(path.join(ws, 'x.js'), '1');
  assert.throws(() => mcp.showArtifact({ path: path.join(ws, 'x.js') }), /\.html/);
  fs.writeFileSync(path.join(tmp, 'outside.html'), 'x');
  assert.throws(() => mcp.showArtifact({ path: path.join(tmp, 'outside.html') }), /must be under/);
  fs.symlinkSync(path.join(tmp, 'outside.html'), path.join(ws, 'link.html'));
  assert.throws(() => mcp.showArtifact({ path: path.join(ws, 'link.html') }), /must be under/);
});

test('the MCP server speaks JSON-RPC over stdio', async () => {
  const p = spawn(process.execPath, [path.join(__dirname, '..', 'scripts', 'cb-mcp.js')], { cwd: path.join(ws, 's'), env: process.env });
  const out = [];
  let buf = '';
  p.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { out.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1); } });
  const send = (o) => p.stdin.write(JSON.stringify(o) + '\n');
  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {} } });
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  send({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
  send({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'show_artifact', arguments: { path: '.artifacts/pricing.html', title: 'Pricing' } } });
  send({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'show_artifact', arguments: { path: 'missing.html' } } });
  for (let i = 0; i < 50 && out.length < 4; i++) await new Promise((r) => setTimeout(r, 50));
  p.stdin.end();
  const by = Object.fromEntries(out.map((m) => [m.id, m]));
  assert.strictEqual(by[1].result.serverInfo.name, 'claude-box');
  assert.deepStrictEqual(by[2].result.tools.map((t) => t.name), ['show_artifact']);
  const line = by[3].result.content[0].text.split('\n')[1];
  assert.strictEqual(JSON.parse(line).path, page);
  assert.strictEqual(by[4].result.isError, true);
});

test('the file route: sandboxed, only artifact files under the allowed folders', async () => {
  const srv = http.createServer((req, res) => art.serve(req, res, req.url));
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const get = (p) => new Promise((resolve) => http.get({ host: '127.0.0.1', port: srv.address().port, path: p }, (r) => {
    let b = ''; r.on('data', (d) => { b += d; }); r.on('end', () => resolve({ status: r.statusCode, h: r.headers, b }));
  }));
  try {
    const ok = await get(page.split('/').map(encodeURIComponent).join('/'));
    assert.strictEqual(ok.status, 200);
    assert.match(ok.h['content-security-policy'], /^sandbox allow-scripts/);
    assert.doesNotMatch(ok.h['content-security-policy'], /allow-same-origin/);
    assert.match(ok.h['content-security-policy'], /frame-ancestors 'self'/);
    assert.strictEqual((await get(encodeURI(path.join(tmp, 'outside.html')))).status, 403);
    assert.strictEqual((await get(encodeURI(path.join(ws, 'x.js')))).status, 415);
    assert.strictEqual((await get(encodeURI(path.join(ws, 'link.html')))).status, 403);
    assert.strictEqual((await get(encodeURI(ws + '/s/../../outside.html'))).status, 403);
    const snap = fs.readdirSync(snaps).map((d) => path.join(snaps, d, fs.readdirSync(path.join(snaps, d))[0]))[0];
    assert.strictEqual((await get(encodeURI(snap))).status, 200, 'snapshots are served too');
    assert.ok(art.stat(page).mtime > 0);
    assert.strictEqual(art.stat(path.join(tmp, 'outside.html')).error, 403);
  } finally { srv.close(); }
});

test('artifact serving covers the session folder (~/.claude/projects)', () => {
  // show_artifact writes to .artifacts/ of the session folder (~/.claude/projects/<slug>/…), and
  // the panel opens that original path for the latest version — the serve roots must include it
  const projDir = path.join(process.env.HOME, '.claude', 'projects', '-w-x', 'sess1');
  fs.mkdirSync(path.join(projDir, '.artifacts'), { recursive: true });
  const f = path.join(projDir, '.artifacts', 'board.html');
  fs.writeFileSync(f, '<h1>board</h1>');
  const prev = process.env.CB_ARTIFACT_SERVE_ROOTS;
  delete process.env.CB_ARTIFACT_SERVE_ROOTS;                     // exercise the built-in defaults
  try {
    const served = art.resolveFile(f);
    assert.ok(!served.error, 'resolveFile rejected the session folder: ' + served.error);
    assert.strictEqual(fs.readFileSync(served.real, 'utf8'), '<h1>board</h1>');
  } finally { if (prev !== undefined) process.env.CB_ARTIFACT_SERVE_ROOTS = prev; }
});
