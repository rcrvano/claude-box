# claude-box.dev landing page

Static, no-runtime landing page for **claude-box.dev**. Served as plain files
(`index.html` + `styles.css` + `main.js` + `fonts/` + `favicon.svg`). No CDN, no
framework, no build step in the serve path — `styles.css` is pre-generated and committed.

## Design

Direction: **"Control room"** — a light operator console wrapping dark terminal screens.
Full rationale and tokens in [`DESIGN-NOTES.md`](./DESIGN-NOTES.md).

- **Palette:** paper `#F7F8FA`, ink `#0E1116`, slate `#5B6573`, line `#E6E9EF`,
  accent iris `#5B5BD6`, coral `#D97757` (reserved for the agent's voice — the Claude nod),
  status live/wait/stop used only inside product mockups.
- **Type (self-hosted woff2):** Space Grotesk (display), Inter (body), IBM Plex Mono (mono).
- **Signature:** the live session board in the hero.

## Regenerate CSS (author-side only)

```bash
# one-time: download the standalone Tailwind CLI (not committed, gitignored)
curl -sL -o bin/tailwindcss https://github.com/tailwindlabs/tailwindcss/releases/download/v3.4.17/tailwindcss-linux-x64
chmod +x bin/tailwindcss

# rebuild styles.css after editing index.html / src/input.css / tailwind.config.js
./bin/tailwindcss -i site/src/input.css -o site/styles.css --minify
```

Tokens live in `tailwind.config.js`; bespoke components (board, window, schematic,
feature list, statusline) live in `site/src/input.css` under `@layer components`.

## Fonts

Self-hosted in `site/fonts/` (no Google Fonts at runtime). To refresh from Fontsource:

```bash
base=https://cdn.jsdelivr.net/fontsource/fonts
curl -sL -o site/fonts/space-700.woff2 "$base/space-grotesk@latest/latin-700-normal.woff2"
curl -sL -o site/fonts/plex-400.woff2  "$base/ibm-plex-mono@latest/latin-400-normal.woff2"
# …and the other weights referenced in src/input.css @font-face
```

## Preview locally

```bash
# any static file server works; e.g.
python3 -m http.server 8099 --directory site      # http://localhost:8099
# or, if python isn't available:
npx --yes serve site
```

Then check the three reference widths: **375px** (mobile), **768px** (tablet), **1280px** (desktop).

## Progressive enhancement

`main.js` is optional — the page is fully readable and usable without it. JS only adds:
copy-to-clipboard, the live GitHub star count + contributors strip, the mobile nav,
the "See all features" expand, and scroll-reveal. With JS off, the full feature list is
shown and the toggle button is hidden.

## Accessibility

Single `<h1>`, `header`/`nav`/`main`/`footer` landmarks, a "Skip to content" link,
visible keyboard focus, `aria-hidden` on decorative terminal mockups, and
`prefers-reduced-motion` respected (no cursor blink / no reveal animation).

## Content accuracy

Only ship claims the code supports. Notably: claude-box ships `defaultMode: auto`
(auto-accept) but deliberately keeps the dangerous-mode prompt — copy says
"auto-accept, safely boxed", never "zero prompts". Star count and contributors are
live from the GitHub API; the `1.2k` in mockups is placeholder.

## Deploy

Any static host. Publish directory = `site/`. Point claude-box.dev at it
(Cloudflare Pages / GitHub Pages / Netlify). No build command needed on the host —
`styles.css` is committed.
