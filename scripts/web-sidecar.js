#!/usr/bin/env node
'use strict';
// Lightweight HTTP sidecar in front of ttyd. Single origin:
//   /            -> launcher (html/launcher.html)
//   /sessions    -> claude-web-registry list (JSON)
//   /metrics     -> claude-web-metrics (JSON)
//   /chat/ws     -> web chat over the Claude Agent SDK (claude-web-chat.js), /chat/info, /dirs
//   /categories  -> GET/POST the sidebar categories (~/.claude/web-categories.json)
//   /workspace   -> folder page: GET list, POST /workspace/{mkdir,rename,clone} (claude-web-workspace.js)
//   /term,/token,/ws -> proxy to the internal ttyd (127.0.0.1:TTYD_PORT)
const http = require('http');
const https = require('https');
const net = require('net');
const fs = require('fs');
const { execFile } = require('child_process');

const IFACE = process.env.WEB_TERMINAL_INTERFACE || '127.0.0.1';
const PORT  = parseInt(process.env.WEB_TERMINAL_PORT || '7681', 10);
const TLS_PORT = parseInt(process.env.WEB_TLS_PORT || '8443', 10);   // https listener (if a cert is present)
const TTYD  = parseInt(process.env.TTYD_PORT || '7682', 10);
const LAUNCHER = process.env.WEB_LAUNCHER || '/usr/local/share/claude-web/launcher.html';
const PW = process.env.WEB_TERMINAL_PASSWORD || '';

// Web chat module (HTML UI over the Agent SDK). Optional: if it fails to load, the launcher
// falls back to console-only and everything else keeps working.
let chat = null;
try { chat = require(process.env.WEB_CHAT_MODULE || '/usr/local/lib/claude-web/web-chat.js'); }
catch (e) { console.error('web chat disabled:', e.message); }
// Sidebar categories: user-made groups + session -> category assignments. Stored server-side
// so every device (desktop, phone) sees the same layout. Shape: {cats:[{id,name}], map:{token:id}}.
const CATS_FILE = process.env.WEB_CATEGORIES || require('path').join(process.env.HOME || '/home/node', '.claude', 'web-categories.json');
function readCats() {
  try { const o = JSON.parse(fs.readFileSync(CATS_FILE, 'utf8')); return { cats: o.cats || [], map: o.map || {} }; }
  catch (_) { return { cats: [], map: {} }; }
}
function cleanCats(o) {
  const str = (v, n) => String(v == null ? '' : v).slice(0, n);
  const cats = (Array.isArray(o && o.cats) ? o.cats : []).slice(0, 100)
    .map((c) => ({ id: str(c && c.id, 40), name: str(c && c.name, 80) })).filter((c) => c.id && c.name);
  const ids = new Set(cats.map((c) => c.id)), map = {};
  Object.entries((o && typeof o.map === 'object' && o.map) || {}).slice(0, 5000)
    .forEach(([k, v]) => { if (ids.has(String(v))) map[str(k, 64)] = String(v); });
  return { cats, map };
}
function writeCats(o) {
  const tmp = CATS_FILE + '.' + process.pid + '.tmp';
  fs.mkdirSync(require('path').dirname(CATS_FILE), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(o)); fs.renameSync(tmp, CATS_FILE);
}
let workspace = null;
try { workspace = require(process.env.WEB_WORKSPACE_MODULE || '/usr/local/lib/claude-web/web-workspace.js'); }
catch (e) { console.error('workspace manager disabled:', e.message); }
// small JSON request bodies only
function readJson(req, limit, cb) {
  let body = '', big = false;
  req.on('data', (d) => { body += d; if (body.length > limit) { big = true; req.destroy(); } });
  req.on('end', () => { if (big) return; let o = null; try { o = JSON.parse(body || '{}'); } catch (_) {} cb(o); });
}
function json(res, code, obj) {
  try { res.writeHead(code, { 'content-type': 'application/json' }); res.end(typeof obj === 'string' ? obj : JSON.stringify(obj)); } catch (_) {}
}

// The sidecar is a long-lived proxy: NO single bad request must crash the process,
// otherwise ALL WS sessions break at once. Swallow uncaught errors, don't exit.
process.on('uncaughtException', (e) => console.error('uncaught:', (e && e.stack) || e));
process.on('unhandledRejection', (e) => console.error('unhandledRejection:', (e && e.stack) || e));

// decodeURIComponent throws URIError on malformed %-encoding — don't crash because of it.
function safeDecode(s) { try { return decodeURIComponent(s); } catch (_) { return s; } }

// basic-auth: the sidecar serves /sessions (session names/paths) and the launcher — when a
// password is set they MUST sit behind the same barrier as the terminal. The login is claude.
function authed(req) {
  if (!PW) return true;
  const m = /^Basic (.+)$/.exec(req.headers['authorization'] || '');
  if (!m) return false;
  try { return Buffer.from(m[1], 'base64').toString() === 'claude:' + PW; } catch (_) { return false; }
}

function proxy(req, res) {
  const opts = { host: '127.0.0.1', port: TTYD, method: req.method, path: req.url, headers: req.headers };
  const up = http.request(opts, r => {
    if (!res.headersSent) res.writeHead(r.statusCode, r.headers);
    r.pipe(res);
  });
  // An upstream error can arrive AFTER headers have already been sent -> a second writeHead
  // would throw ERR_HTTP_HEADERS_SENT. Guard + try so this doesn't crash the process.
  up.on('error', () => { try { if (!res.headersSent) res.writeHead(502); res.end('ttyd down'); } catch (_) {} });
  res.on('error', () => up.destroy());
  req.on('error', () => up.destroy());
  req.pipe(up);
}

const handler = (req, res) => {
  try {
    if (!authed(req)) {
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="claude-box"' });
      res.end('auth required'); return;
    }
    const path = req.url.split('?')[0];
    if (path === '/sessions') {
      execFile('claude-web-registry', ['list'], { maxBuffer: 4 << 20 }, (e, out) => {
        if (e) { json(res, 500, '[]'); return; }
        let rows; try { rows = JSON.parse(out); } catch (_) { json(res, 500, '[]'); return; }
        json(res, 200, chat ? chat.decorate(rows) : rows);
      });
      return;
    }
    if (path === '/chat/info') {
      if (!chat) { json(res, 200, { enabled: false, error: 'chat module not loaded' }); return; }
      chat.info().then((i) => json(res, 200, i), () => json(res, 200, { enabled: false }));
      return;
    }
    if (path === '/dirs') { json(res, 200, chat ? chat.dirs() : []); return; }
    if (path === '/rename' && req.method === 'POST') {
      // rename a session (custom-title in its transcript, same as Claude Code's /rename)
      const m = /(?:^|&)id=([^&]*)/.exec(req.url.split('?')[1] || '');
      let body = '';
      req.on('data', (d) => { body += d; if (body.length > 4096) req.destroy(); });
      req.on('end', () => {
        let title = ''; try { title = JSON.parse(body).title; } catch (_) {}
        if (!chat || !m) { json(res, 400, { ok: false }); return; }
        chat.rename(safeDecode(m[1]), title).then((t) => json(res, 200, { ok: true, title: t }),
          (e) => json(res, 400, { ok: false, error: String(e.message || e) }));
      });
      return;
    }
    if (path === '/workspace' || path.startsWith('/workspace/')) {
      if (!workspace) { json(res, 503, { error: 'workspace manager not loaded' }); return; }
      if (req.method !== 'POST') { json(res, 200, workspace.list()); return; }
      readJson(req, 8192, (o) => {
        try {
          if (!o) throw new Error('bad request');
          const op = path.slice('/workspace/'.length);
          const r = op === 'mkdir' ? workspace.mkdir(o.name)
            : op === 'rename' ? workspace.rename(o.from, o.to)
            : op === 'clone' ? workspace.clone(o.url, o.name)
            : null;
          if (!r) { json(res, 404, { error: 'unknown op' }); return; }
          json(res, 200, Object.assign({ ok: true }, r));
        } catch (e) { json(res, 400, { ok: false, error: String(e.message || e) }); }
      });
      return;
    }
    if (path === '/categories') {
      if (req.method !== 'POST') { json(res, 200, readCats()); return; }
      let body = '', big = false;
      req.on('data', (d) => { body += d; if (body.length > 512 << 10) { big = true; req.destroy(); } });
      req.on('end', () => {
        if (big) return;
        try { const o = cleanCats(JSON.parse(body)); writeCats(o); json(res, 200, o); }
        catch (e) { json(res, 400, { error: String(e.message || e) }); }
      });
      return;
    }
    if (path === '/') {
      fs.readFile(LAUNCHER, (e, buf) => {
        try {
          if (e) { res.writeHead(500); res.end('no launcher'); return; }
          res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(buf);
        } catch (_) {}
      });
      return;
    }
    if (path === '/metrics') {
      const m = /[?&]id=([^&]*)/.exec(req.url);
      const args = m ? ['--id', safeDecode(m[1])] : [];
      execFile('claude-web-metrics', args, { maxBuffer: 1 << 20 }, (e, out) => {
        try { res.writeHead(e ? 500 : 200, { 'content-type': 'application/json' }); res.end(e ? '{}' : out); } catch (_) {}
      });
      return;
    }
    if (path === '/preview') {
      const q = req.url.split('?')[1] || '';
      const m = /(?:^|&)id=([^&]*)/.exec(q);
      if (!m) { try { res.writeHead(400, { 'content-type': 'application/json' }); res.end('{}'); } catch (_) {} return; }
      const args = [safeDecode(m[1])];
      if (/(?:^|&)full=1(?:&|$)/.test(q)) args.push('--full');
      execFile('claude-web-preview', args, { maxBuffer: 4 << 20 }, (e, out) => {
        try { res.writeHead(e ? 500 : 200, { 'content-type': 'application/json' }); res.end(e ? '{}' : out); } catch (_) {}
      });
      return;
    }
    if (path === '/delete' && req.method === 'POST') {
      // remove a session from the dashboard (registry + cache + kill its tmux). POST only,
      // so a stray GET/prefetch can't wipe a session. Behind the authed() barrier.
      const q = req.url.split('?')[1] || '';
      const m = /(?:^|&)id=([^&]*)/.exec(q);
      if (!m) { try { res.writeHead(400, { 'content-type': 'application/json' }); res.end('{"ok":false}'); } catch (_) {} return; }
      const tok = safeDecode(m[1]);
      Promise.resolve(chat && chat.stopByToken(tok)).catch(() => {}).then(() => {
        execFile('claude-web-registry', ['delete', tok], { maxBuffer: 1 << 20 }, (e) => {
          json(res, e ? 500 : 200, e ? '{"ok":false}' : '{"ok":true}');
        });
      });
      return;
    }
    if (path === '/search') {
      const q = req.url.split('?')[1] || '';
      const mq = /(?:^|&)q=([^&]*)/.exec(q);
      // a query string encodes a space as '+', which decodeURIComponent leaves untouched
      const query = mq ? safeDecode(mq[1].replace(/\+/g, ' ')) : '';
      if (query.trim().length < 2) {                    // empty/too short -> don't invoke the helper
        try { res.writeHead(200, { 'content-type': 'application/json' }); res.end('[]'); } catch (_) {}
        return;
      }
      const capped = query.slice(0, 200);               // cap on query length
      const ms = /(?:^|&)scope=([^&]*)/.exec(q);
      const scope = (ms && safeDecode(ms[1]) === 'all') ? 'all' : 'prompts';
      execFile('claude-web-search', [capped, '--scope', scope],
        { maxBuffer: 4 << 20, timeout: 20000 }, (e, out) => {   // headroom for the "tail" of frequent queries over a large corpus
          try { res.writeHead(e ? 500 : 200, { 'content-type': 'application/json' }); res.end(e ? '[]' : out); } catch (_) {}
        });
      return;
    }
    // everything else (/term, /token, ttyd static assets) -> ttyd
    proxy(req, res);
  } catch (e) {
    console.error('handler error:', (e && e.stack) || e);
    try { if (!res.headersSent) res.writeHead(500); res.end(); } catch (_) {}
  }
};

// TLS: if web-serve passed a cert+key and they are readable -> https, otherwise http (as before).
let tls = null;
if (process.env.WEB_TLS_CERT && process.env.WEB_TLS_KEY) {
  try { tls = { cert: fs.readFileSync(process.env.WEB_TLS_CERT), key: fs.readFileSync(process.env.WEB_TLS_KEY) }; }
  catch (e) { console.error('tls read failed, fallback http:', e.message); }
}
// WebSocket upgrade (/ws) -> ttyd. Shared by the http and https servers.
function onUpgrade(req, socket, head) {
  try {
    if (!authed(req)) { socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return; }
    if (req.url.split('?')[0] === '/chat/ws') {
      if (!chat) { socket.end('HTTP/1.1 503 Service Unavailable\r\n\r\n'); return; }
      chat.handleUpgrade(req, socket, head); return;
    }
    const up = net.connect(TTYD, '127.0.0.1', () => {
      up.write(`${req.method} ${req.url} HTTP/1.1\r\n` +
        Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n') + '\r\n\r\n');
      if (head && head.length) up.write(head);
      socket.pipe(up); up.pipe(socket);
    });
    up.on('error', () => socket.destroy());
    socket.on('error', () => up.destroy());
  } catch (_) { try { socket.destroy(); } catch (__) {} }
}

// Two independent listeners on DIFFERENT ports (network_mode: host, no mapping needed):
//   http  on WEB_TERMINAL_PORT — always works; over a LAN IP this is an insecure context,
//          so the browser has NO clipboard or notifications, but the terminal works.
//   https on WEB_TLS_PORT      — secure context: clipboard + notifications (needs a cert).
// No redirect: each port serves the terminal on its own scheme, the user chooses.
const httpServer = http.createServer(handler);
httpServer.on('upgrade', onUpgrade);
httpServer.listen(PORT, IFACE, () => console.error(`sidecar http://${IFACE}:${PORT} -> ttyd ${TTYD}`));

if (tls) {
  const httpsServer = https.createServer(tls, handler);
  httpsServer.on('upgrade', onUpgrade);
  httpsServer.listen(TLS_PORT, IFACE, () => console.error(`sidecar https://${IFACE}:${TLS_PORT} -> ttyd ${TTYD}`));
}
