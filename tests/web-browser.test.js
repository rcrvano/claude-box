'use strict';
// web-browser.js: the Browser tab's server side. The viewer page and noVNC's files are served
// without paths outside noVNC's folder; the WebSocket bridge relays bytes both ways between the
// browser tab and the VNC unix socket (a stand-in VNC server here, no Chromium needed).
// Run: node --test tests/
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const net = require('net');
const path = require('path');
const http = require('http');

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'cb-br-')));
const novnc = path.join(tmp, 'novnc'), page = path.join(tmp, 'browser.html'), dir = path.join(tmp, 'run');
fs.mkdirSync(path.join(novnc, 'core'), { recursive: true });
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(novnc, 'core', 'rfb.js'), 'export default 1;');
fs.writeFileSync(page, '<!doctype html><title>Browser</title>');
fs.writeFileSync(path.join(tmp, 'secret.txt'), 'no');
Object.assign(process.env, { CB_NOVNC_DIR: novnc, CB_BROWSER_PAGE: page, CB_BROWSER_DIR: dir, CB_CHROMIUM: path.join(tmp, 'no-chromium') });
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const b = require('../scripts/web-browser.js');
let WSS = null;
for (const m of [process.env.WEB_CHAT_MODULES || '/opt/claude-web-chat/node_modules', 'ws']) {
  try { WSS = require(m === 'ws' ? 'ws' : path.join(m, 'ws')).WebSocketServer; break; } catch (_) {}
}

test('off unless the box was started with --browser (and Chromium is there)', () => {
  delete process.env.WEB_BROWSER;
  assert.strictEqual(b.enabled(), false);
  process.env.WEB_BROWSER = '1';
  assert.strictEqual(b.enabled(), false, 'no Chromium binary');
});

test('the viewer page and noVNC files are served; nothing outside noVNC', async () => {
  const srv = http.createServer((req, res) => b.serve(req, res, req.url));
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const get = (p) => new Promise((res) => http.get({ host: '127.0.0.1', port: srv.address().port, path: p }, (r) => {
    let s = ''; r.on('data', (d) => { s += d; }); r.on('end', () => res({ status: r.statusCode, type: r.headers['content-type'], body: s }));
  }));
  try {
    const v = await get('/');
    assert.strictEqual(v.status, 200); assert.match(v.body, /<title>Browser/);
    const j = await get('/core/rfb.js');
    assert.strictEqual(j.status, 200); assert.match(j.type, /javascript/);
    assert.strictEqual((await get('/../secret.txt')).status, 404);
    assert.strictEqual((await get('/..%2fsecret.txt')).status, 404);
    assert.strictEqual((await get('/core/missing.js')).status, 404);
  } finally { srv.close(); }
});

test('the WebSocket bridge relays bytes to and from the VNC socket', { skip: !WSS && 'ws is not installed here (it is in the image)' }, async () => {
  const sock = b.VNC_SOCK;
  const got = [];
  const vnc = net.createServer((c) => { c.write('RFB 003.008\n'); c.on('data', (d) => { got.push(String(d)); c.write('echo:' + d); }); });
  await new Promise((r) => vnc.listen(sock, r));
  const srv = http.createServer();
  srv.on('upgrade', (req, s, h) => b._bridge(req, s, h, WSS));
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  try {
    const msgs = await new Promise((resolve, reject) => {
      const ws = new WebSocket('ws://127.0.0.1:' + srv.address().port + '/browser/websockify', ['binary']);
      ws.binaryType = 'arraybuffer'; const out = [];
      ws.onmessage = (e) => { out.push(Buffer.from(e.data).toString()); if (out.length === 1) ws.send(Buffer.from('RFB 003.008\n')); else { ws.close(); resolve(out); } };
      ws.onerror = () => reject(new Error('ws error'));
      setTimeout(() => reject(new Error('timeout')), 5000);
    });
    assert.strictEqual(msgs[0], 'RFB 003.008\n');
    assert.strictEqual(msgs[1], 'echo:RFB 003.008\n');
    assert.deepStrictEqual(got, ['RFB 003.008\n']);
  } finally { srv.close(); vnc.close(); }
});

test('the brand list reads like Google Chrome: added next to Chromium, GREASE kept', () => {
  const m = b.chromeMeta([{ brand: 'Not:A-Brand', version: '8' }, { brand: 'Chromium', version: '156' }],
    [{ brand: 'Not:A-Brand', version: '8.0.0.0' }, { brand: 'Chromium', version: '156.0.8078.108' }], '156.0.8078.108');
  assert.deepStrictEqual(m.brands.map((x) => x.brand + '/' + x.version), ['Not:A-Brand/8', 'Google Chrome/156', 'Chromium/156']);
  assert.deepStrictEqual(m.fullVersionList.map((x) => x.version), ['8.0.0.0', '156.0.8078.108', '156.0.8078.108']);
  assert.strictEqual(m.platform, 'Linux'); assert.strictEqual(m.architecture, 'x86'); assert.strictEqual(m.mobile, false);
  // without Chromium's own list (the probe failed): still both names
  assert.deepStrictEqual(b.chromeMeta(null, null, '156.0.1.2').brands.map((x) => x.brand), ['Google Chrome', 'Chromium']);
});

test('the screen follows the tab, within limits', async () => {
  assert.deepStrictEqual(await b.resize(1281, 801), { changed: true, w: 1280, h: 800 });
  assert.deepStrictEqual(await b.resize(1280, 800), { changed: false, w: 1280, h: 800 });
  assert.deepStrictEqual(await b.resize(100, 50), { changed: true, w: 640, h: 400 });
  assert.deepStrictEqual(await b.resize(99999, 99999), { changed: true, w: 7680, h: 4320 });
});

test('a Slack permalink opens in the web app (no "Launching…" page) once the team id is known', () => {
  const T = 'T0123ABCD', p = 'https://acme.slack.com/archives/C0456EFGH/p1795610923135229';
  assert.strictEqual(b.slackWebUrl(p, T), 'https://app.slack.com/client/T0123ABCD/C0456EFGH/thread/C0456EFGH-1795610923.135229');
  // a reply's link opens its thread (the parent's ts)
  assert.strictEqual(b.slackWebUrl('https://acme.slack.com/archives/C0456EFGH/p1795610999000100?thread_ts=1795610923.135229&cid=C0456EFGH', T),
    'https://app.slack.com/client/T0123ABCD/C0456EFGH/thread/C0456EFGH-1795610923.135229');
  assert.strictEqual(b.slackWebUrl('https://acme.slack.com/archives/C0456EFGH', T), 'https://app.slack.com/client/T0123ABCD/C0456EFGH');
  assert.strictEqual(b.slackWebUrl(p, ''), null, 'no team id yet: the permalink itself');
  assert.strictEqual(b.slackWebUrl('https://app.slack.com/client/T1/C1', T), null);
});
