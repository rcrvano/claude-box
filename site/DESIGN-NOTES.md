# claude-box.dev — design notes

**Direction:** "Control room" — a light operator console wrapping dark terminal screens.
Light page, dark screens (honest to the product), status = color.

## Tokens
- paper `#F7F8FA` · panel `#FFFFFF` · ink `#0E1116` · slate `#5B6573` · line `#E6E9EF`
- accent: iris `#5B5BD6` / iris-ink `#4848C7` (the box / controls / CTA)
- coral `#D97757` — reserved for **the agent's voice** (`claude ▸`, its cursor). The only Claude nod.
- status (inside product mockups only): live `#16A34A` · wait `#E0A100` · stop `#9aa7b8`
- screen: bg `#0E1116` / bar `#171A21` / line `#262B36` / text `#C9CFDA`

## Type
- display: **Space Grotesk** (700/500) — headlines, restraint
- body: **Inter** (400/600)
- mono: **IBM Plex Mono** (400/500/600) — terminals, labels, statusline, eyebrows

## Signature
**Live session board** in the hero — the launcher grid of dark session cards with
status-colored left edges + a coral `claude ▸` card. The one memorable thing.

## Structure decisions (from user feedback)
- Headline feature = **automode**: "let it run on auto" + the box makes it safe
  (can't steal → egress proxied; can't break → only /workspace mounted).
- **Containment boundary** schematic (FIG.1) brought over from direction B.
- **Features as a list**: 3 highlighted + "See all" expands the full set;
  nav "Features" opens the full list.
- **Docker** surfaced prominently (Claude *in Docker*).
- **ngrok / phone access** folded into the web-terminal deep-dive + a features item.

## Honesty guardrails
- automode = `defaultMode:auto` (auto-accept). claude-box deliberately does NOT skip the
  dangerous-mode prompt — do not claim "zero prompts ever". Frame as "auto-accept, safely boxed".
- Star count + contributors are live from GitHub API; mockup `1.2k` is placeholder.
- Only claim shipped capabilities: docker sandbox, web terminal (ttyd), launcher previews,
  notifications, tunnel (ngrok), VS Code (code-server), MCP servers, superpowers, deep-links.
