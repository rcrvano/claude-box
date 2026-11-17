# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## Language conventions

- **All code comments MUST be written in English.** No Russian (or other
  non-English) comments in any source file — shell, JS, Dockerfile, YAML, HTML, CSS, etc.
- **All user-facing strings in code MUST be in English** too: shell `echo`/`printf`
  output, menu items, prompts, error messages, web UI text, log lines.
- **Documentation (README, INSTALL, etc.) is in English.**
- This applies to new code and to any file you touch — if you edit a file that still
  has non-English text, translate it as part of your change.

## Project shape (quick orientation)

- `claude-box` — host entry point (launch / attach / `--web` / `--tunnel`).
- `scripts/` — in-container menu, web terminal (ttyd) sidecar, launcher, metrics, notify.
  `scripts/web-chat.js` — web chat mode: Claude Agent SDK sessions streamed to the launcher over `/chat/ws`.
- `site/` — the static marketing landing for **claude-box.dev** (Tailwind, self-hosted
  fonts, no CDN; deploy with `./site/deploy.sh`).
- `html/` — the in-product web terminal / session launcher pages.

## Secrets & safety

- Never read, print, or commit `.env` or `certs/*.crt` (they are gitignored and
  permission-denied). `.env.example` is the public template — keep it English and secret-free.
