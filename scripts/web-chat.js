'use strict';
// claude-box web chat: drives Claude sessions through the Claude Agent SDK and streams them to
// the browser over ONE multiplexed WebSocket (/chat/ws). Loaded by claude-web-sidecar.
//
// A Claude session is driven by exactly ONE owner at a time:
//   chat    — an Agent SDK query() owned by this module (HTML UI in the launcher)
//   console — `claude --resume` inside tmux (the classic terminal, via ttyd)
// Switching hands the session over: "release" stops the chat process before the console
// starts; "takeover" kills the console's tmux session before the chat resumes. Both write the
// same ~/.claude/projects/<cwd>/<id>.jsonl, so history carries over in both directions.
//
// Wire protocol (JSON text frames). `key` is the client's handle for a session: a registry
// token, or a client-made "new-N" for a session that has no Claude id yet.
//   client -> server:
//     {op:'open', key, token?, cwd?}   subscribe (+ history); cwd for a brand-new session
//     {op:'close', key}                unsubscribe
//     {op:'send', key, text}           user message (starts/resumes the SDK process lazily)
//     {op:'interrupt', key}            stop the current turn
//     {op:'perm', key, id, allow, always?, answers?}   answer a permission / question request
//     {op:'mode', key, mode}           permission mode (default|acceptEdits|plan|auto)
//     {op:'release', key}              stop the chat process (before switching to console)
//     {op:'takeover', key}             kill the console tmux session (before switching to chat)
//   server -> client:
//     {ev:'history', key, items, state, console, info}
//     {ev:'msg', key, m}               raw SDK message (assistant/user/stream_event/result/system)
//     {ev:'state', key, state}         idle | running | requires_action | starting | stopped
//     {ev:'token', key, token}         the session now has a registry token (new or after /clear)
//     {ev:'perm', key, id, tool, input, reason, suggestions}
//     {ev:'perm_done', key, id}
//     {ev:'info', key, info}           model, permissionMode, cwd, slash commands, last cost
//     {ev:'released', key} / {ev:'console', key, active}
//     {ev:'error', key, text}

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { pathToFileURL } = require('url');

const MODULES = process.env.WEB_CHAT_MODULES || '/opt/claude-web-chat/node_modules';
const IDLE_MIN = parseInt(process.env.WEB_CHAT_IDLE_MINUTES || '60', 10);   // stop idle SDK processes
const WS_ROOT = process.env.WORKSPACE_DIR || '/workspace';

let WebSocketServer = null, sdk = null, loadError = null;
try {
  WebSocketServer = require(path.join(MODULES, 'ws')).WebSocketServer;
} catch (e) { loadError = 'ws module not found: ' + e.message; }
const sdkReady = (async () => {
  if (loadError) return;
  try {
    // The SDK is ESM-only; import it by absolute path (it lives outside the sidecar's module tree).
    // WEB_CHAT_SDK overrides it (used by the tests with a mock SDK).
    const p = process.env.WEB_CHAT_SDK ||
      require.resolve('@anthropic-ai/claude-agent-sdk', { paths: [MODULES] });
    sdk = await import(pathToFileURL(p).href);
  } catch (e) { loadError = 'Agent SDK not available: ' + e.message; }
})();

function log(...a) { console.error('[chat]', ...a); }
function sh(cmd, args) {
  return new Promise((res) => execFile(cmd, args, { maxBuffer: 4 << 20 }, (e, out) => res(e ? null : String(out))));
}
const registry = {
  async get(token) { const o = await sh('claude-web-registry', ['get', token]); try { return o ? JSON.parse(o) : null; } catch (_) { return null; } },
  async upsert(f) {
    const a = ['upsert', '--claude-id', f.cid, '--cwd', f.cwd || '', '--name', f.name || '', '--tmux', f.name || '',
      '--state', f.state || '', '--mode', 'chat'];
    if (f.title) a.push('--title', f.title);
    return ((await sh('claude-web-registry', a)) || '').trim();
  },
};
async function tmuxAlive(name) {
  if (!name) return false;
  return (await sh('tmux', ['has-session', '-t', '=' + name])) !== null;
}

// ---------- async input queue for the SDK's streaming-input mode ----------
class InputQueue {
  constructor() { this.items = []; this.waiters = []; this.done = false; }
  push(v) { const w = this.waiters.shift(); if (w) w({ value: v, done: false }); else this.items.push(v); }
  end() { this.done = true; this.waiters.splice(0).forEach((w) => w({ value: undefined, done: true })); }
  [Symbol.asyncIterator]() {
    return { next: () => this.items.length ? Promise.resolve({ value: this.items.shift(), done: false })
      : this.done ? Promise.resolve({ value: undefined, done: true })
      : new Promise((r) => this.waiters.push(r)) };
  }
}

// ---------- one chat-owned Claude session ----------
const CHATS = new Set();            // all live Chat objects
const BY_CID = new Map();           // claude session id -> Chat
let permSeq = 0, newSeq = 0;

class Chat {
  constructor({ cid, cwd, name, token }) {
    this.cid = cid || null; this.cwd = cwd; this.name = name; this.token = token || null;
    this.subs = new Set();            // {ws, key}
    this.state = 'stopped'; this.q = null; this.input = null;
    this.perms = new Map();           // id -> {resolve, tool, input, reason, suggestions}
    this.turn = [];                   // SDK messages of the current turn (for late subscribers)
    this.info = { cwd, model: '', permissionMode: '', commands: [], cost: null };
    this.titled = !!token; this.idleTimer = null; this.closing = null;
    CHATS.add(this); if (this.cid) BY_CID.set(this.cid, this);
  }
  emit(obj) {
    for (const s of this.subs) {
      try { s.ws.send(JSON.stringify(Object.assign({ key: s.key }, obj))); } catch (_) {}
    }
  }
  setState(st) {
    if (this.state === st) return;
    this.state = st; this.emit({ ev: 'state', state: st });
    clearTimeout(this.idleTimer);
    if (st === 'idle' && IDLE_MIN > 0) this.idleTimer = setTimeout(() => this.stop(), IDLE_MIN * 60000);
    const reg = { running: 'working', requires_action: 'waiting', idle: 'done' }[st];
    if (reg && this.cid) this.syncRegistry(reg);
  }
  async syncRegistry(state, title) {
    const tok = await registry.upsert({ cid: this.cid, cwd: this.cwd, name: this.name, state, title });
    if (tok && tok !== this.token) { this.token = tok; this.emit({ ev: 'token', token: tok }); }
  }
  async start() {
    await sdkReady;
    if (!sdk) throw new Error(loadError || 'Agent SDK not loaded');
    if (this.cid && await tmuxAlive(this.name)) throw new Error('This session is open in the console. Switch to chat first (it closes the console).');
    this.input = new InputQueue();
    const options = {
      cwd: this.cwd,
      includePartialMessages: true,
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      canUseTool: (tool, input, o) => this.askPermission(tool, input, o),
      // claude-notify (the tmux hook) must not touch the registry for chat-owned sessions —
      // this module keeps those records itself (see scripts/notify.sh).
      env: Object.assign({}, process.env, { CLAUDE_WEB_CHAT: '1' }),
      stderr: (d) => log(this.name, String(d).trim()),
    };
    if (this.cid) options.resume = this.cid;
    if (this.desiredMode) options.permissionMode = this.desiredMode;   // picked before the first message
    this.setState('starting');
    this.q = sdk.query({ prompt: this.input, options });
    this.loop();
  }
  async loop() {
    try {
      for await (const m of this.q) this.onMessage(m);
    } catch (e) {
      log(this.name, 'query failed:', e && e.message);
      this.emit({ ev: 'error', text: String((e && e.message) || e) });
    }
    this.q = null; this.input = null; this.turn = [];
    for (const [id, p] of this.perms) { p.resolve({ behavior: 'deny', message: 'session stopped' }); this.emit({ ev: 'perm_done', id }); }
    this.perms.clear();
    this.setState('stopped');
    if (this.cid && BY_CID.get(this.cid) === this) BY_CID.delete(this.cid);
    if (!this.subs.size) CHATS.delete(this);
    if (this.closing) { this.closing(); this.closing = null; }
  }
  onMessage(m) {
    if (m.type === 'system' && m.subtype === 'init') {
      if (m.session_id && m.session_id !== this.cid) {        // new session, or a fork on resume
        if (this.cid && BY_CID.get(this.cid) === this) BY_CID.delete(this.cid);
        this.cid = m.session_id; BY_CID.set(this.cid, this);
        this.syncRegistry('working', this.titled ? '' : this.pendingTitle);
        this.titled = true;
      }
      this.info = Object.assign(this.info, { model: m.model, permissionMode: m.permissionMode,
        cwd: m.cwd || this.cwd, commands: m.slash_commands || [] });
      this.emit({ ev: 'info', info: this.info });
      return;
    }
    if (m.type === 'system' && m.subtype === 'session_state_changed') { this.setState(m.state); return; }
    if (m.type === 'system' && m.subtype === 'status' && m.permissionMode) {
      this.info.permissionMode = m.permissionMode; this.emit({ ev: 'info', info: this.info });
    }
    if (m.type === 'result') {
      this.info.cost = m.total_cost_usd; this.emit({ ev: 'info', info: this.info });
      this.turn = [];
      this.emit({ ev: 'msg', m });
      if (this.state !== 'requires_action') this.setState('idle');
      return;
    }
    if (m.type === 'assistant' || m.type === 'user' || m.type === 'stream_event' ||
        (m.type === 'system' && (m.subtype === 'local_command_output' || m.subtype === 'compact_boundary'))) {
      if (this.state !== 'running' && this.state !== 'requires_action' && m.type !== 'system') this.setState('running');
      if (m.type !== 'stream_event') this.turn.push(m);
      this.emit({ ev: 'msg', m });
    }
  }
  askPermission(tool, input, o) {
    return new Promise((resolve) => {
      const id = 'p' + (++permSeq);
      const p = { resolve, tool, input, reason: o && o.decisionReason, suggestions: (o && o.suggestions) || [] };
      this.perms.set(id, p);
      this.setState('requires_action');
      this.emit({ ev: 'perm', id, tool, input, reason: p.reason, suggestions: p.suggestions.length > 0 });
      p.done = () => {
        this.perms.delete(id); this.emit({ ev: 'perm_done', id });
        if (!this.perms.size && this.q) this.setState('running');   // the turn continues
      };
      if (o && o.signal) o.signal.addEventListener('abort', () => {
        if (!this.perms.has(id)) return;
        resolve({ behavior: 'deny', message: 'cancelled' }); p.done();
      });
    });
  }
  answer(id, msg) {
    const p = this.perms.get(id); if (!p) return;
    if (p.tool === 'AskUserQuestion' && msg.answers) {
      p.resolve({ behavior: 'allow', updatedInput: Object.assign({}, p.input, { answers: msg.answers }) });
    } else if (msg.allow) {
      const r = { behavior: 'allow', updatedInput: p.input };
      if (msg.always && p.suggestions.length) r.updatedPermissions = p.suggestions;
      p.resolve(r);
    } else {
      p.resolve({ behavior: 'deny', message: msg.message || 'The user denied this action.' });
    }
    p.done();
  }
  async send(text) {
    if (!this.titled && !this.pendingTitle) this.pendingTitle = text.replace(/\s+/g, ' ').trim().slice(0, 80);
    if (!this.q) await this.start();
    clearTimeout(this.idleTimer);
    this.input.push({ type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null });
  }
  async interrupt() { if (this.q) { try { await this.q.interrupt(); } catch (e) { log('interrupt', e.message); } } }
  async setMode(mode) {
    if (!['default', 'acceptEdits', 'plan', 'auto'].includes(mode)) return;
    this.desiredMode = mode;
    if (this.q) await this.q.setPermissionMode(mode);
    this.info.permissionMode = mode; this.emit({ ev: 'info', info: this.info });
  }
  stop() {
    if (!this.q) return Promise.resolve();
    return new Promise((res) => {
      this.closing = res;
      try { this.input.end(); } catch (_) {}
      try { this.q.close(); } catch (_) {}
      setTimeout(() => { if (this.closing) { this.closing(); this.closing = null; } }, 5000);
    });
  }
}

// ---------- history ----------
async function history(chat) {
  if (!chat.cid) return [];
  await sdkReady;
  let items = [];
  try { items = sdk ? await sdk.getSessionMessages(chat.cid, { dir: chat.cwd }) : []; }
  catch (e) { log('history', e.message); }
  // add what the SDK has streamed this turn but the transcript doesn't have yet
  const seen = new Set(items.map((i) => i.uuid));
  for (const m of chat.turn) if (!seen.has(m.uuid)) items.push(m);
  return items.filter((i) => i.type === 'user' || i.type === 'assistant')
    .map((i) => ({ type: i.type, uuid: i.uuid, message: i.message, parent_tool_use_id: i.parent_tool_use_id || null }));
}

// ---------- per-socket handling ----------
function sanitizeName(s) { return String(s || '').replace(/[^A-Za-z0-9_-]/g, '-').slice(0, 40) || 'chat'; }
async function chatFor(msg) {
  if (msg.token) {
    const rec = await registry.get(msg.token);
    if (!rec) throw new Error('unknown session');
    const ex = BY_CID.get(rec.claudeSessionId);
    if (ex) return ex;
    for (const c of CHATS) if (c.token === msg.token) return c;
    return new Chat({ cid: rec.claudeSessionId, cwd: rec.cwd, name: rec.tmuxSession || rec.name || ('chat-' + msg.token), token: msg.token });
  }
  const cwd = msg.cwd && path.resolve(msg.cwd);
  if (!cwd || !fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) throw new Error('folder not found: ' + msg.cwd);
  return new Chat({ cwd, name: 'chat-' + sanitizeName(path.basename(cwd)) + '-' + Date.now().toString(36).slice(-4) + (++newSeq) });
}

function onConnection(ws) {
  const mine = new Map();      // key -> Chat
  const reply = (o) => { try { ws.send(JSON.stringify(o)); } catch (_) {} };
  // Handle a socket's messages strictly in order: 'open' is async (registry + history), and the
  // ops that follow it (send/takeover/...) must see the session it opened.
  let chain = Promise.resolve();
  ws.on('message', (raw) => { chain = chain.then(() => handle(raw)).catch((e) => log('ws op failed:', e && e.message)); });
  async function handle(raw) {
    let msg; try { msg = JSON.parse(String(raw)); } catch (_) { return; }
    const key = String(msg.key || '');
    try {
      if (msg.op === 'open') {
        let chat = mine.get(key);
        if (!chat) { chat = await chatFor(msg); mine.set(key, chat); chat.subs.add({ ws, key }); }
        const items = await history(chat);
        const pend = [...chat.perms].map(([id, p]) => ({ id, tool: p.tool, input: p.input, reason: p.reason, suggestions: p.suggestions.length > 0 }));
        reply({ ev: 'history', key, items, state: chat.state, console: !chat.q && await tmuxAlive(chat.name),
                info: chat.info, perms: pend, token: chat.token });
        return;
      }
      const chat = mine.get(key);
      if (!chat) { reply({ ev: 'error', key, text: 'session not open' }); return; }
      switch (msg.op) {
        case 'close':
          for (const s of chat.subs) if (s.ws === ws && s.key === key) chat.subs.delete(s);
          mine.delete(key);
          if (!chat.subs.size && !chat.q) CHATS.delete(chat);
          break;
        case 'send': if (msg.text && String(msg.text).trim()) await chat.send(String(msg.text)); break;
        case 'interrupt': await chat.interrupt(); break;
        case 'perm': chat.answer(msg.id, msg); break;
        case 'mode': await chat.setMode(String(msg.mode)); break;
        case 'release': await chat.stop(); reply({ ev: 'released', key }); break;
        case 'takeover':
          if (await tmuxAlive(chat.name)) {
            await sh('tmux', ['kill-session', '-t', '=' + chat.name]);      // SIGHUP -> Claude flushes
            for (let i = 0; i < 25 && await tmuxAlive(chat.name); i++) await new Promise((r) => setTimeout(r, 200));
            await new Promise((r) => setTimeout(r, 400));
          }
          reply({ ev: 'console', key, active: false });
          break;
      }
    } catch (e) {
      reply({ ev: 'error', key, text: String((e && e.message) || e) });
    }
  }
  ws.on('close', () => {
    for (const [key, chat] of mine) {
      for (const s of chat.subs) if (s.ws === ws && s.key === key) chat.subs.delete(s);
      if (!chat.subs.size && !chat.q) CHATS.delete(chat);
    }
    mine.clear();
  });
}

let wss = null;
function handleUpgrade(req, socket, head) {
  if (!WebSocketServer) { socket.end('HTTP/1.1 503 Service Unavailable\r\n\r\n'); return; }
  if (!wss) { wss = new WebSocketServer({ noServer: true, maxPayload: 8 << 20 }); wss.on('connection', onConnection); }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
}

// ---------- session titles from the transcript ----------
// Claude Code keeps a session's name in its JSONL: `custom-title` (set by /rename or the
// sidebar's Rename) and `ai-title` (auto-generated). The registry only has what the hooks saw
// (the first prompt / terminal title), so the sidebar label is resolved from the transcript.
// Transcripts are append-only, so we cache per file and only read the bytes added since last time.
const HOME = process.env.HOME || '/home/node';
const PROJECTS = path.join(HOME, '.claude', 'projects');
const TITLES = new Map();          // cid -> {file, size, custom, ai}
function transcriptPath(cid, cwd) {
  const guess = path.join(PROJECTS, String(cwd || '').replace(/[^a-zA-Z0-9]/g, '-'), cid + '.jsonl');
  if (fs.existsSync(guess)) return guess;
  try {
    for (const d of fs.readdirSync(PROJECTS)) {
      const f = path.join(PROJECTS, d, cid + '.jsonl'); if (fs.existsSync(f)) return f;
    }
  } catch (_) {}
  return null;
}
const TITLE_RE = /"type":"(custom-title|ai-title)","(?:customTitle|aiTitle)":"((?:[^"\\]|\\.)*)"/g;
function sessionTitles(cid, cwd) {
  if (!cid) return null;
  let t = TITLES.get(cid);
  if (!t || !t.file) { t = { file: transcriptPath(cid, cwd), size: 0, custom: '', ai: '' }; TITLES.set(cid, t); }
  if (!t.file) { TITLES.delete(cid); return null; }
  let st; try { st = fs.statSync(t.file); } catch (_) { TITLES.delete(cid); return null; }
  if (st.size < t.size) { t.size = 0; t.custom = ''; t.ai = ''; }              // rewritten
  if (st.size > t.size) {
    const fd = fs.openSync(t.file, 'r');
    try {
      const start = Math.max(0, t.size - 1024);                                 // overlap: a line cut last time
      const buf = Buffer.alloc(st.size - start); fs.readSync(fd, buf, 0, buf.length, start);
      const text = buf.toString('utf8'); let m; TITLE_RE.lastIndex = 0;
      while ((m = TITLE_RE.exec(text))) {
        let v; try { v = JSON.parse('"' + m[2] + '"'); } catch (_) { v = m[2]; }
        if (m[1] === 'custom-title') t.custom = v; else t.ai = v;
      }
    } finally { fs.closeSync(fd); }
    t.size = st.size;
  }
  return t;
}

async function rename(token, title) {
  title = String(title || '').replace(/\s+/g, ' ').trim().slice(0, 120);
  if (!title) throw new Error('empty title');
  const rec = await registry.get(token);
  if (!rec || !rec.claudeSessionId) throw new Error('unknown session');
  await sdkReady;
  if (sdk && sdk.renameSession) {
    await sdk.renameSession(rec.claudeSessionId, title, { dir: rec.cwd });
  } else {                                                                      // SDK unavailable: same entry by hand
    const f = transcriptPath(rec.claudeSessionId, rec.cwd);
    if (!f) throw new Error('transcript not found');
    fs.appendFileSync(f, JSON.stringify({ type: 'custom-title', customTitle: title, sessionId: rec.claudeSessionId }) + '\n');
  }
  return title;
}

// Overlay live chat state and transcript titles onto the registry list (registry only knows tmux).
function decorate(rows) {
  rows = rows.map((r) => {
    const t = sessionTitles(r.claudeSessionId, r.cwd);
    const title = (t && (t.custom || t.ai)) || r.title;
    return title === r.title ? r : Object.assign({}, r, { title });
  });
  return rows.map((r) => {
    const c = BY_CID.get(r.claudeSessionId);
    if (c && c.q) {
      const st = { running: 'working', requires_action: 'waiting', idle: 'done', starting: 'working' }[c.state] || r.state;
      return Object.assign({}, r, { live: true, mode: 'chat', state: st });
    }
    return Object.assign({}, r, { mode: r.live ? 'console' : (r.mode || 'console') });
  });
}

// Workspace folders for the "new chat" picker, most recently modified first.
function dirs() {
  let out = [];
  try {
    out = fs.readdirSync(WS_ROOT, { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith('.'))
      .map((d) => { const p = path.join(WS_ROOT, d.name); let t = 0; try { t = fs.statSync(p).mtimeMs; } catch (_) {} return { path: p, name: d.name, mtime: t }; })
      .sort((a, b) => b.mtime - a.mtime);
  } catch (_) {}
  return [{ path: WS_ROOT, name: path.basename(WS_ROOT) + ' (root)', mtime: 0 }].concat(out);
}

async function stopByToken(token) {
  for (const c of CHATS) if (c.token === token) await c.stop();
}

async function info() { await sdkReady; return { enabled: !!sdk, error: loadError }; }

module.exports = { handleUpgrade, decorate, dirs, stopByToken, info, rename };
