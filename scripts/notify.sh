#!/usr/bin/env bash
# claude-box: Claude signal (bell + browser/terminal tab title).
#   claude-notify done     -> 🟢 <session>  + bell   (Claude finished the reply)
#   claude-notify waiting  -> 🟡 <session>  + bell   (waiting for input/permission)
#   claude-notify working  -> ⏳ <session>            (given a new task, no bell)
# Markers are emoji: you can't set a color in a tab title, so we use distinctly
# shaped symbols (a green circle stands out more than a monochrome check mark on a dark tab).
# We take the session name from tmux (#S), otherwise "claude". We write to the pane tty
# (or CLAUDE_NOTIFY_TTY — for tests). Never crash Claude.
set -uo pipefail

state="${1:-done}"

# IMPORTANT (multi-tab): we resolve the session/window of EXACTLY the pane where the hook fired.
# The hook inherits $TMUX_PANE from Claude. Without -t "$TMUX_PANE", tmux takes the "current"
# session of the active client (the last active tab) → the signal would go to the wrong tab.
pane="${TMUX_PANE:-}"
if [ -n "$pane" ]; then
  sess="$(tmux display-message -p -t "$pane" '#S' 2>/dev/null || true)"
  win="$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null || true)"
else
  sess="$(tmux display-message -p '#S' 2>/dev/null || true)"
  win="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
fi
[ -n "$sess" ] || sess="claude"
pane_tty="$(tmux display-message -p -t "${pane:-}" '#{pane_tty}' 2>/dev/null || true)"
# Claude's own terminal title (OSC) -> tmux pane_title. This is the meaningful name shown
# in the browser tab; we persist it so the launcher can label the card with it (not web-N).
ptitle="$(tmux display-message -p -t "${pane:-}" '#{pane_title}' 2>/dev/null || true)"

# --- Web session registry (durable): from the hook's stdin we take claudeSessionId + cwd. ---
# Claude Code passes JSON to the hook on stdin. We read ONLY if stdin is a pipe
# (otherwise a manual claude-notify call from the terminal would hang on the read). We send the
# token from the registry to the browser via private OSC 5379 -> html/index.html sets ?id=<token>.
if [ ! -t 0 ]; then
  hook_json="$(cat 2>/dev/null || true)"
  cid="$(printf '%s' "$hook_json" | jq -r '.session_id // empty' 2>/dev/null)"
  hcwd="$(printf '%s' "$hook_json" | jq -r '.cwd // empty' 2>/dev/null)"
  if [ -n "$cid" ]; then
    [ -n "$hcwd" ] || hcwd="$PWD"
    token="$(claude-web-registry upsert \
      --claude-id "$cid" --cwd "$hcwd" --name "$sess" --state "$state" --tmux "$sess" --title "$ptitle" 2>/dev/null)"
    [ -n "$token" ] && printf '\033]5379;%s\007' "$token" > "${pane_tty:-/dev/tty}" 2>/dev/null || true
  fi
fi

case "$state" in
  done)    mark='🟢'; bell=1 ;;
  waiting) mark='🟡'; bell=1 ;;
  working) mark='⏳'; bell=0 ;;
  *)       mark='🟢'; bell=1 ;;
esac

tty="${CLAUDE_NOTIFY_TTY:-/dev/tty}"
title="$mark $sess"

# The WINDOW name (which, unlike pane_title, the application doesn't overwrite with allow-rename/
# automatic-rename off) -> set-titles -> tab title. The marker is STATIC: the waiting blink
# is now done by the client (html/index.html) based on tab visibility, and it clears the yellow
# as soon as the tab is opened. Here we just silence any blinker left over from the old version.
blink_file="/tmp/claude-notify-blink.${sess//[^A-Za-z0-9_-]/_}.pid"
if [ -f "$blink_file" ]; then kill "$(cat "$blink_file" 2>/dev/null)" 2>/dev/null || true; rm -f "$blink_file"; fi
[ -n "$win" ] && tmux rename-window -t "$win" "$title" 2>/dev/null || true

# Fallback for NON-tmux (a regular terminal) + bell: OSC title and bell straight to the tty.
{
  printf '\033]2;%s\007' "$title"
  [ "$bell" -eq 1 ] && printf '\a'
} > "$tty" 2>/dev/null || true
