'use strict';
// claude-box workspace manager for the launcher's folder page: list /workspace folders (with git
// info), create, rename, and clone git repositories. Loaded by claude-web-sidecar.
// Every path is confined to WORKSPACE_DIR: names are single path segments, never paths.

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const ROOT = process.env.WORKSPACE_DIR || '/workspace';

function safeName(n) {
  n = String(n == null ? '' : n).trim();
  if (!n || n.length > 120 || n === '.' || n === '..' || /[\/\\\0]/.test(n) || n.startsWith('.')) {
    throw new Error('invalid folder name (no "/", must not start with ".")');
  }
  return n;
}

// git info straight from .git (no subprocess per folder): branch + origin URL without credentials
function gitInfo(dir) {
  const g = path.join(dir, '.git');
  let head;
  try { head = fs.readFileSync(path.join(g, 'HEAD'), 'utf8').trim(); } catch (_) { return null; }
  const m = /^ref: refs\/heads\/(.+)$/.exec(head);
  const info = { branch: m ? m[1] : head.slice(0, 8) };
  try {
    const cfg = fs.readFileSync(path.join(g, 'config'), 'utf8');
    const r = /\[remote "origin"\][^[]*?url\s*=\s*(\S+)/.exec(cfg);
    if (r) info.remote = r[1].replace(/\/\/[^@/]+@/, '//');      // drop user:token@
  } catch (_) {}
  return info;
}

function list() {
  let ents = [];
  try { ents = fs.readdirSync(ROOT, { withFileTypes: true }); } catch (_) {}
  const cloning = new Set([...JOBS.values()].filter((j) => j.state === 'running').map((j) => j.name));
  const out = ents.filter((d) => d.isDirectory() && !d.name.startsWith('.') && !cloning.has(d.name)).map((d) => {
    const p = path.join(ROOT, d.name); let mtime = 0;
    try { mtime = fs.statSync(p).mtimeMs; } catch (_) {}
    return { name: d.name, path: p, mtime, git: gitInfo(p) };
  });
  return { root: ROOT, dirs: out, jobs: jobList() };
}

function mkdir(name) {
  const p = path.join(ROOT, safeName(name));
  if (fs.existsSync(p)) throw new Error('already exists: ' + name);
  fs.mkdirSync(p);
  return { path: p };
}

function rename(from, to) {
  const a = path.join(ROOT, safeName(from)), b = path.join(ROOT, safeName(to));
  if (!fs.existsSync(a)) throw new Error('not found: ' + from);
  if (fs.existsSync(b)) throw new Error('already exists: ' + to);
  fs.renameSync(a, b);
  return { path: b };
}

// ---------- git clone as a background job (big repos outlive an HTTP request) ----------
const JOBS = new Map(); let jobSeq = 0;
function jobList() {
  return [...JOBS.values()].slice(-10).map((j) => ({ id: j.id, url: j.url, name: j.name, path: j.path, state: j.state, error: j.error, started: j.started }));
}
function repoName(url) {
  const m = /([^/:]+?)(?:\.git)?\/?$/.exec(String(url).trim());
  return m ? m[1] : '';
}
function clone(url, name) {
  url = String(url || '').trim();
  // https://host/..., ssh://..., git@host:org/repo — no options smuggled as the URL
  if (!/^(https?:\/\/|ssh:\/\/|git@[\w.-]+:)[^\s]+$/.test(url)) throw new Error('unsupported git URL');
  const dirName = safeName(name || repoName(url));
  const target = path.join(ROOT, dirName);
  if (fs.existsSync(target)) throw new Error('already exists: ' + dirName);
  const id = 'j' + (++jobSeq);
  const job = { id, url: url.replace(/\/\/[^@/]+@/, '//'), name: dirName, path: target, state: 'running', error: '', started: Date.now() };
  JOBS.set(id, job);
  execFile('git', ['clone', '--', url, target],
    { cwd: ROOT, timeout: 30 * 60000, maxBuffer: 8 << 20, env: Object.assign({}, process.env, { GIT_TERMINAL_PROMPT: '0' }) },
    (e, _out, err) => {
      if (e) { job.state = 'error'; job.error = (String(err || e.message).trim().split('\n').pop() || 'clone failed').slice(0, 300); }
      else job.state = 'done';
    });
  return { id, name: dirName, path: target };
}

module.exports = { list, mkdir, rename, clone };
