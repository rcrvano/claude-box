'use strict';
// The artifact panel's files (see cb-mcp.js show_artifact). Served by web-sidecar.js behind the login:
//   GET /artifact/f/<absolute path>   the file, in a CSP sandbox: an opaque origin, so the page can
//                                     run its scripts but cannot read the box's cookies or call its API
//   GET /artifact/stat?p=<abs path>   {mtime, size}: the panel reloads the live version when it changes
// Only files under /workspace or the snapshot folder, and only .html/.htm/.svg/.md.
const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME || '/home/node';
const SNAP_DIR = process.env.CB_ARTIFACT_DIR || path.join(HOME, '.claude', 'web-artifacts');
// show_artifact writes to .artifacts/ of the session folder (~/.claude/projects/<slug>/…), so the
// projects dir must be servable too, or the panel's latest version renders a bare "403" page.
const ROOTS = () => (process.env.CB_ARTIFACT_SERVE_ROOTS ||
  ['/workspace', path.join(HOME, '.claude', 'projects')].join(':')).split(':').filter(Boolean).concat([SNAP_DIR]);
const TYPES = { '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.svg': 'image/svg+xml', '.md': 'text/plain; charset=utf-8' };
// the page may load scripts, styles, fonts and images from anywhere (CDNs) but stays sandboxed
const CSP = "sandbox allow-scripts allow-forms allow-popups allow-modals; frame-ancestors 'self'; " +
  "default-src * data: blob: 'unsafe-inline' 'unsafe-eval'";

function resolveFile(p) {
  const abs = path.resolve('/', String(p || ''));
  let real; try { real = fs.realpathSync(abs); } catch (_) { return { error: 404 }; }
  const roots = ROOTS().map((r) => { try { return fs.realpathSync(r); } catch (_) { return r; } });
  if (!roots.some((r) => real === r || real.startsWith(r.replace(/\/+$/, '') + '/'))) return { error: 403 };
  const type = TYPES[path.extname(real).toLowerCase()];
  if (!type) return { error: 415 };
  let st; try { st = fs.statSync(real); } catch (_) { return { error: 404 }; }
  if (!st.isFile()) return { error: 404 };
  return { real, type, st };
}

function serve(req, res, rel) {
  let p; try { p = decodeURIComponent(rel); } catch (_) { p = ''; }
  const f = resolveFile(p);
  if (f.error) { res.writeHead(f.error, { 'content-type': 'text/plain' }); res.end(f.error === 403 ? 'not an artifact folder' : f.error === 415 ? 'not an artifact file' : 'not found'); return; }
  res.writeHead(200, { 'content-type': f.type, 'content-security-policy': CSP, 'cache-control': 'no-store',
    'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' });
  fs.createReadStream(f.real).on('error', () => res.end()).pipe(res);
}

function stat(p) {
  const f = resolveFile(p);
  if (f.error) return { error: f.error };
  return { mtime: f.st.mtimeMs, size: f.st.size };
}

module.exports = { serve, stat, resolveFile, CSP };
