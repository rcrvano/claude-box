#!/usr/bin/env bash
# On-disk registry of web sessions (survives a container restart, unlike tmux).
# Single I/O point: everyone writes/reads only through this helper (flock + jq).
#   upsert --claude-id <id> --cwd <p> --name <n> --state <s> --tmux <sess> [--title t] [--mode chat|console] -> token
#   get <token>   -> JSON of the record (exit 1 if not found)
#   list          -> JSON array, newest first, with a live field (tmux has-session)
#   delete <token>-> kill the tmux session (if alive) + erase the record and preview cache
#   snapshot      -> save the tokens of the currently running sessions (web-live-sessions.json)
#   restore       -> after a container restart, recreate those sessions with claude --resume
set -uo pipefail

REG="${CLAUDE_WEB_REGISTRY:-$HOME/.claude/web-sessions.json}"
LIVE="${CLAUDE_WEB_LIVE:-$(dirname "$REG")/web-live-sessions.json}"
mkdir -p "$(dirname "$REG")"
[ -f "$REG" ] || echo '{}' > "$REG"

gen_token() { local u; u="$(cat /proc/sys/kernel/random/uuid)"; u="${u//-/}"; printf '%s' "${u:0:8}"; }

cmd="${1:-}"; shift || true

case "$cmd" in
  upsert)
    cid=""; cwd=""; name=""; state=""; tmux=""; title=""; mode=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --claude-id) cid="$2"; shift 2;;
        --cwd)       cwd="$2"; shift 2;;
        --name)      name="$2"; shift 2;;
        --state)     state="$2"; shift 2;;
        --tmux)      tmux="$2"; shift 2;;
        --title)     title="$2"; shift 2;;
        --mode)      mode="$2"; shift 2;;       # chat | console (last owner); kept if omitted
        *) shift;;
      esac
    done
    [ -n "$cid" ] || { echo "upsert: --claude-id required" >&2; exit 2; }
    exec 9>"$REG.lock"; flock 9
    token="$(jq -r --arg c "$cid" 'to_entries[]|select(.value.claudeSessionId==$c)|.key' "$REG" 2>/dev/null | head -n1)"
    [ -n "$token" ] || token="$(gen_token)"
    ts="$(date +%s)"
    tmp="$(mktemp)"
    jq --arg t "$token" --arg c "$cid" --arg cwd "$cwd" --arg n "$name" \
       --arg s "$state" --arg tm "$tmux" --arg ti "$title" --arg mo "$mode" --argjson ts "$ts" \
       '.[$t] = {token:$t, claudeSessionId:$c, cwd:$cwd, name:$n, state:$s, tmuxSession:$tm,
                 title: (if ($ti|length)>0 then $ti else (.[$t].title // "") end),
                 mode: (if ($mo|length)>0 then $mo else (.[$t].mode // "") end),
                 lastActivity:$ts}' \
       "$REG" > "$tmp" && mv "$tmp" "$REG"
    printf '%s' "$token"
    ;;
  get)
    jq -e --arg t "${1:-}" '.[$t] // empty' "$REG"
    ;;
  list)
    # array, newest first, + live via tmux has-session
    # For a live session prefer its CURRENT pane_title (Claude's own title — same string the
    # browser tab shows); for a dead one fall back to the last title stored at hook time.
    jq -c '[.[]] | sort_by(-.lastActivity) | .[]' "$REG" 2>/dev/null | while IFS= read -r rec; do
      sess="$(printf '%s' "$rec" | jq -r '.tmuxSession // ""')"
      if [ -n "$sess" ] && tmux has-session -t "$sess" 2>/dev/null; then
        live=true; pt="$(tmux display-message -p -t "$sess" '#{pane_title}' 2>/dev/null || true)"
      else
        live=false; pt=""
      fi
      printf '%s\n' "$rec" | jq -c --argjson live "$live" --arg pt "$pt" \
        '. + {live:$live, title: (if ($pt|length)>0 then $pt else (.title // "") end)}'
    done | jq -s '.'
    ;;
  delete)
    # remove the session from the dashboard: kill ITS tmux session (if alive; specifically
    # kill-session -t <the specific one>, not kill-server), erase the record from the registry and the preview cache.
    tok="${1:-}"
    [ -n "$tok" ] || { echo "delete: token required" >&2; exit 2; }
    exec 9>"$REG.lock"; flock 9
    sess="$(jq -r --arg t "$tok" '.[$t].tmuxSession // empty' "$REG" 2>/dev/null || true)"
    [ -n "$sess" ] && tmux kill-session -t "$sess" 2>/dev/null || true
    tmp="$(mktemp)"
    jq --arg t "$tok" 'del(.[$t])' "$REG" > "$tmp" && mv "$tmp" "$REG"
    rm -f "$HOME/.claude/web-previews/$tok.ansi" 2>/dev/null || true
    printf 'ok'
    ;;
  snapshot)
    # Remember which sessions are running RIGHT NOW (tokens -> $LIVE), so a container restart
    # can bring them back (see restore). Called periodically and on shutdown by claude-web-serve.
    # A tmux session may own several records (e.g. after /clear Claude starts a new session id
    # in the same pane) -> keep only the most recently active record per tmux session.
    names="$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"
    tmp="$(mktemp "$LIVE.XXXXXX")" || exit 1
    if jq -c --arg names "$names" '
         ($names | split("\n") | map(select(length > 0))) as $alive
         | [.[] | select(.tmuxSession as $s | any($alive[]; . == $s))]
         | group_by(.tmuxSession) | map(max_by(.lastActivity) | .token)' "$REG" > "$tmp"; then
      mv "$tmp" "$LIVE"
    else
      rm -f "$tmp"; exit 1
    fi
    ;;
  restore)
    # Bring back the sessions recorded by the last snapshot: each one gets its tmux session
    # (same name as before) running `claude --resume <id>` in its original cwd.
    [ -s "$LIVE" ] || exit 0
    jq -r '.[]?' "$LIVE" 2>/dev/null | while IFS= read -r tok; do
      rec="$(jq -c --arg t "$tok" '.[$t] // empty' "$REG" 2>/dev/null)"
      [ -n "$rec" ] || continue                           # deleted from the dashboard meanwhile
      cid="$(printf '%s' "$rec" | jq -r '.claudeSessionId // empty')"
      cwd="$(printf '%s' "$rec" | jq -r '.cwd // empty')"
      sess="$(printf '%s' "$rec" | jq -r '.tmuxSession // empty')"
      [ -n "$sess" ] || sess="web-$tok"
      if [ -z "$cid" ] || [ ! -d "$cwd" ]; then
        echo "restore: skip $sess (folder $cwd is gone)" >&2; continue
      fi
      tmux has-session -t "=$sess" 2>/dev/null && continue   # already running
      if tmux -u new-session -d -s "$sess" -c "$cwd" claude --resume "$cid" 2>/dev/null; then
        echo "restore: $sess -> claude --resume $cid ($cwd)" >&2
      else
        echo "restore: failed to start $sess" >&2
      fi
      sleep 0.5      # stagger startups: they all touch the shared ~/.claude.json
    done
    ;;
  *)
    echo "usage: claude-web-registry upsert|get|list|delete|snapshot|restore" >&2; exit 2;;
esac
