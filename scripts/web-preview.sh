#!/usr/bin/env bash
# Screenshot of a tmux session for the launcher preview. Prints JSON {ansi,live,ts}.
#   claude-web-preview <token> [--full]
# Live session -> tmux capture-pane -ep (+ caches the FULL frame to disk, survives restart).
# Dead -> last cached frame (live:false, ts=mtime). No cache -> ansi:"".
# Without --full: last 12 lines (thumbnail). With --full: the whole visible screen.
set -uo pipefail

token="${1:-}"
full=0
[ "${2:-}" = "--full" ] && full=1
[ -n "$token" ] || { printf '{"ansi":"","live":false,"ts":0}'; exit 0; }

rec="$(claude-web-registry get "$token" 2>/dev/null || true)"
sess="$(printf '%s' "$rec" | jq -r '.tmuxSession // empty' 2>/dev/null || true)"

# Optional isolated tmux socket. Empty (prod) -> default socket, the same one real
# sessions use. Set (CLAUDE_TMUX_L=name) -> separate socket: tests NEVER touch the
# user's live sessions (and definitely never call kill-server on the default one).
tmux_cmd=(tmux); [ -n "${CLAUDE_TMUX_L:-}" ] && tmux_cmd=(tmux -L "$CLAUDE_TMUX_L")

dir="$HOME/.claude/web-previews"; mkdir -p "$dir" 2>/dev/null || true
cache="$dir/$token.ansi"

cap=""; live=false; ts=0
if [ -n "$sess" ] && "${tmux_cmd[@]}" has-session -t "$sess" 2>/dev/null; then
  cap="$("${tmux_cmd[@]}" capture-pane -ep -t "$sess" 2>/dev/null || true)"
  printf '%s' "$cap" > "$cache" 2>/dev/null || true     # cache the FULL frame
  live=true; ts="$(date +%s)"
elif [ -f "$cache" ]; then
  cap="$(cat "$cache" 2>/dev/null || true)"
  live=false; ts="$(stat -c %Y "$cache" 2>/dev/null || echo 0)"
fi

# thumbnail -> last 12 lines; full -> as is
if [ "$full" -eq 0 ] && [ -n "$cap" ]; then
  cap="$(printf '%s' "$cap" | tail -n 12)"
fi

# jq -Rs: safely encodes ANSI/newlines into a JSON string
printf '%s' "$cap" | jq -Rs --argjson live "$live" --argjson ts "$ts" '{ansi:., live:$live, ts:$ts}'
