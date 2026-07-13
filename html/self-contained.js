#!/usr/bin/env node
// Shared safeguard for the web-terminal page builders (build-index.js / build-launcher.js).
//
// The built pages are served as a SINGLE file each (ttyd --index serves one file; the sidecar
// serves the launcher the same way), and the terminal they host has shell access — so the page
// must never pull an asset from a CDN or any other remote origin. This module is the one place
// that decides what counts as a violation, so the two builders cannot drift apart.
'use strict';

// Only flag URLs in positions the browser actually FETCHES: src=/href= attributes, CSS url(),
// and @import. Matching bare "https?://" anywhere would flag things that are never fetched and
// are not violations — attribution comments inside vendored JS (xterm.js credits term.js and
// jslinux), and xmlns="http://www.w3.org/2000/svg" namespace identifiers on <svg>.
// Protocol-relative (//cdn.example/x.js) counts too: it fetches.
const FETCHING_REFS = [
  /(?:src|href)\s*=\s*["'](?:https?:)?\/\/[^"']+/gi,
  /url\(\s*["']?(?:https?:)?\/\/[^"')]+/gi,
  /@import\s+["'](?:https?:)?\/\/[^"']+/gi,
];

// The ws:// and /token endpoints are built at runtime from location, never baked into the page,
// so they never appear in a fetching position — no allowlist needed here.

// Returns the external references the built page would fetch (empty == self-contained).
function findExternalRefs(html) {
  const hits = [];
  for (const re of FETCHING_REFS) hits.push(...(html.match(re) || []));
  return hits;
}

// Fail the build (rather than warn): a page that quietly reaches out to a CDN defeats the point
// of self-hosting a shell, and a warning scrolls by unnoticed in docker build output. extraChecks
// catch assets the inliner was supposed to embed but did not.
function assertSelfContained(label, html, extraChecks) {
  const bad = findExternalRefs(html);
  for (const [description, re] of extraChecks || []) {
    if (re.test(html)) bad.push(description);
  }
  if (bad.length) {
    console.error(label + ': ERROR — page is not self-contained; remaining references:');
    for (const ref of [...new Set(bad)]) console.error('  ' + ref);
    process.exit(1);
  }
}

module.exports = { findExternalRefs, assertSelfContained };
