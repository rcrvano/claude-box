#!/usr/bin/env bash
# ttyd landing: for each connection (tab) — an fzf picker of tmux sessions.
# "New session" / entering a new name -> tmux new-session with claude-launch inside;
# selecting an existing one -> tmux attach; "Rename session…" -> rename-session.
# Renaming is a separate menu item (not a hotkey): F2/Ctrl-R is intercepted by
# the browser. This way different tabs hold different claude sessions.
#
# Deep-link/registry: the claude-notify hook keeps the records and tokens (web-sessions.json).
# We set ?id= in the browser RELIABLY ourselves — OSC 5379 in stdout before attach (see emit_token),
# rather than through the pane tty from the hook. Argument $1 (ttyd --url-arg from ?id=) is the session token:
# alive → attach, dead (after a restart) → recreate in cwd and claude --resume. new:<name> — create.
set -uo pipefail

NEW='•  New session'
REN='•  ✎ Rename session…'

# next free name web-N (if the user did not enter their own)
next_name() {
  local i=1
  while tmux has-session -t "web-$i" 2>/dev/null; do i=$((i + 1)); done
  printf 'web-%s' "$i"
}

# existing sessions: "<name>  (N windows)", most recent on top
list_sessions() {
  tmux list-sessions -F '#{session_activity}#{session_name}  (#{session_windows} windows)' 2>/dev/null \
    | sort -rn | sed -E 's/^[0-9]+//'
}

# Emit the private OSC 5379 with the session token to stdout (ttyd -> browser -> index.html
# sets ?id=). More reliable than the claude-notify hook in the pane tty: stdout goes straight to xterm.
# We look up the token in the registry by tmux session name (the most recently active one, if there are several).
emit_token() {
  local sess="$1" token
  [ -n "$sess" ] || return 0
  token="$(claude-web-registry list 2>/dev/null \
    | jq -r --arg s "$sess" '[.[] | select(.tmuxSession==$s)] | sort_by(.lastActivity) | last | .token // empty' 2>/dev/null)"
  [ -n "$token" ] && printf '\033]5379;%s\007' "$token"
  return 0
}

# enter a live session (+ OSC with the token to the browser before attach)
enter() {
  emit_token "$1"
  exec tmux -u attach-session -t "$1"        # -u: force UTF-8
}

# enter via deep-link token through the registry (durable, survives a restart):
# tmux session alive -> attach; dead (after a restart) -> recreate + claude --resume.
enter_by_token() {
  local token="$1" rec cid cwd name sess nm
  rec="$(claude-web-registry get "$token" 2>/dev/null)" || return 1
  cid="$(printf '%s'  "$rec" | jq -r '.claudeSessionId // empty')"
  cwd="$(printf '%s'  "$rec" | jq -r '.cwd // empty')"
  name="$(printf '%s' "$rec" | jq -r '.name // empty')"
  sess="$(printf '%s' "$rec" | jq -r '.tmuxSession // empty')"
  if [ -n "$sess" ] && tmux has-session -t "$sess" 2>/dev/null; then
    printf '\033]5379;%s\007' "$token"      # confirm ?id= in the browser
    exec tmux -u attach-session -t "$sess"
  fi
  [ -n "$cid" ] && [ -d "$cwd" ] || return 1
  nm="${name:-resume}"
  tmux has-session -t "$nm" 2>/dev/null && nm="$nm-$token"
  tmux -u new-session -d -s "$nm" -c "$cwd" "claude --resume '$cid'" 2>/dev/null || return 1
  printf '\033]5379;%s\007' "$token"        # same token after resume
  exec tmux -u attach-session -t "$nm"
}

# Plain bash in the container (the launcher's "Terminal"): one persistent tmux session per folder,
# so reopening the terminal returns to the same shell with its history.
shell_and_enter() {
  local dir="${1:-/workspace}" nm
  case "$dir" in /workspace|/workspace/*) ;; *) dir=/workspace ;; esac   # stay inside the workspace
  [ -d "$dir" ] || dir=/workspace
  nm="shell"; [ "$dir" != /workspace ] && nm="shell-$(basename "$dir" | tr -c 'A-Za-z0-9_-' '-')"
  tmux has-session -t "=$nm" 2>/dev/null || tmux -u new-session -d -s "$nm" -c "$dir" bash -l 2>/dev/null || true
  exec tmux -u attach-session -t "$nm"
}

# create a new session and enter it
new_and_enter() {
  local name="$1"
  printf '%s  starting new session: %s%s\n' "$O" "$name" "$R"
  tmux -u new-session -d -s "$name" claude-launch 2>/dev/null || true
  enter "$name"
}

O=$'\033[38;5;208m'; R=$'\033[0m'

# Deep-link: $1 = token (via ttyd --url-arg from ?id=) or new:<name> from the launcher.
if [ -n "${1:-}" ]; then
  case "$1" in
    new:*) nm="${1#new:}"; new_and_enter "${nm:-$(next_name)}";;   # explicit creation
    shell:*) shell_and_enter "${1#shell:}";;      # plain bash in the container (launcher "Terminal")
    *)     enter_by_token "$1";;            # token; not found -> fall through to the menu below
  esac
fi

# The picker runs in a loop: after renaming we show it again.
while true; do
  mapfile -t sessions < <(list_sessions)

  # No sessions yet — no need for the picker, start a new one right away.
  if [ "${#sessions[@]}" -eq 0 ]; then
    new_and_enter "$(next_name)"
  fi

  # --print-query: 1st line of stdout = query; 2nd = the selected line.
  out="$(printf '%s\n' "$NEW" "${sessions[@]}" "$REN" \
    | fzf --print-query --height=60% --reverse --border=rounded --pointer='▶' \
          --color='pointer:208,prompt:208' --prompt='session ▸ ' \
          --header='Enter — select/create · type a name for a new one · Esc — close')"
  rc=$?
  # Esc/Ctrl-C (>=130) -> just close the tab
  [ "$rc" -ge 130 ] && exit 0

  query="$(printf '%s\n' "$out" | sed -n 1p)"
  choice="$(printf '%s\n' "$out" | sed -n 2p)"

  # "Rename…" item: a second picker (which session) -> new name -> back to the menu.
  if [ "$choice" = "$REN" ]; then
    target="$(list_sessions | fzf --height=60% --reverse --border=rounded --pointer='▶' \
                --color='pointer:208,prompt:208' --prompt='rename ▸ ' \
                --header='choose a session · Esc — back')" || continue
    [ -z "$target" ] && continue
    old="${target%% *}"                 # the first token of the line is the session name
    printf '%s  rename "%s" (empty + Enter — cancel)%s\n' "$O" "$old" "$R"
    read -rp '  new name: ' newname
    if [ -n "$newname" ] && [ "$newname" != "$old" ]; then
      tmux rename-session -t "$old" "$newname" 2>/dev/null \
        || printf '  failed (name taken or invalid characters . :)\n' >&2
    fi
    continue
  fi

  # Enter: empty selection/"New session" -> new (name = query or web-N); otherwise attach.
  if [ -z "$choice" ] || [ "$choice" = "$NEW" ]; then
    new_and_enter "${query:-$(next_name)}"
  else
    enter "${choice%% *}"               # the first token of the line is the session name
  fi
done
