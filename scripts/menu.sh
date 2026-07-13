#!/usr/bin/env bash
# Container startup menu: banner + fzf picker (type to filter, ↑↓ to select, Enter)
# over /workspace subfolders (most recent on top) + scratch / new folder / bash.
# If fzf is unavailable — numeric fallback (read).
set -euo pipefail

WS="${WORKSPACE_DIR:-/workspace}"

# --- seed shared defaults: settings (once), mcpServers (synced with the repo) ---
DEF="${CLAUDE_DEFAULTS:-/opt/claude-defaults}"
mkdir -p "$HOME/.claude"
# Serialize seeding of the shared ~/.claude.json: with the web terminal several tmux sessions
# start in parallel and, without a lock, overwrite each other's seed (read-modify-write).
exec 9>"$HOME/.claude/.seed.lock"
flock 9
if [ ! -f "$HOME/.claude/settings.json" ] && [ -f "$DEF/settings.json" ]; then
  cp "$DEF/settings.json" "$HOME/.claude/settings.json"
fi

if [ -f "$DEF/mcp.json" ]; then
  [ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"
  tmp="$(mktemp)"
  jq --slurpfile d "$DEF/mcp.json" '.mcpServers = ((.mcpServers // {}) + $d[0].mcpServers)' "$HOME/.claude.json" > "$tmp" && mv "$tmp" "$HOME/.claude.json"
fi

# OAuth token in .env: skip first-run login wizard (Claude Code ignores env token in onboarding)
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  [ -f "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"
  tmp="$(mktemp)"
  jq '.hasCompletedOnboarding = true' "$HOME/.claude.json" > "$tmp" && mv "$tmp" "$HOME/.claude.json"
fi

# Completion-signal hooks (claude-notify): idempotently set up 3 events.
# CLAUDE_NOTIFY_DISABLE (any non-empty value) — disables installation.
if [ -z "${CLAUDE_NOTIFY_DISABLE:-}" ]; then
  [ -f "$HOME/.claude/settings.json" ] || echo '{}' > "$HOME/.claude/settings.json"
  tmp="$(mktemp)"
  jq '.hooks.Stop             = [{"hooks":[{"type":"command","command":"claude-notify done"}]}]
    | .hooks.Notification     = [{"hooks":[{"type":"command","command":"claude-notify waiting"}]}]
    | .hooks.UserPromptSubmit = [{"hooks":[{"type":"command","command":"claude-notify working"}]}]' \
    "$HOME/.claude/settings.json" > "$tmp" && mv "$tmp" "$HOME/.claude/settings.json"
fi
flock -u 9

# workspace subfolders, most recent (by mtime) on top
mapfile -t dirs < <(find "$WS" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)

SCRATCH="•  Temporary session (scratch, not saved)"
NEWDIR="•  Create a new folder in /workspace…"
BASHC="•  bash in the container"

O=$'\033[38;5;208m'; B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'   # orange / bold / dim / reset
E=$'\033[31m'                                                  # red (errors)

# Report a failure and hold it on screen. The menu redraw clears the terminal (print_header
# sends RIS), so without waiting for a keypress the message would flash by unread.
menu_error() {
  printf '\n  %s✗ %s%s\n' "$E" "$1" "$R" >&2
  shift
  local line
  for line in "$@"; do printf '  %s%s%s\n' "$D" "$line" "$R" >&2; done
  printf '\n'
  read -rsn1 -p '  Press any key to return to the menu…' _ || true
  printf '\n'
}

print_header() {
  printf '\033c'                       # reset the terminal before showing the menu
  printf '\n'
  printf '   %s   ╱▔▔╲%s      %sClaude Box%s\n'   "$O" "$R" "$B" "$R"
  printf '   %s╭─╯ CB ╰─╮%s   %ssandboxed Claude Code in Docker%s\n' "$O" "$R" "$D" "$R"
  printf '   %s╰─◯───◯──╯%s\n\n' "$O" "$R"
}

# full terminal reset before launching claude (RIS — no dependency on ncurses/reset)
run_claude() {
  printf '\033c'
  exec claude "$@"
}

# Create a folder in $WS and start claude in it. Returns non-zero instead of exiting, so the
# caller can redraw the menu: a failure here (usually an unwritable /workspace) must not kill
# the whole menu — under `set -e` a bare `mkdir` did exactly that, bouncing the user out silently.
make_new_dir() {
  local name
  read -rp "  Name of the new folder: " name
  if [ -z "$name" ] || [[ "$name" == */* ]]; then
    menu_error "Invalid folder name." "A name is required and it must not contain '/'."
    return 1
  fi
  if ! mkdir -p "$WS/$name" 2>/dev/null; then
    if [ ! -w "$WS" ]; then
      menu_error "Cannot write to $WS — it is not writable by uid $(id -u)." \
                 "This usually means PROJECT_DIR in .env is unset, points at a missing folder," \
                 "or points at a folder owned by another user: docker then creates the bind-mount" \
                 "source as root and mounts it read-only for us. Fix PROJECT_DIR and restart."
    else
      menu_error "Could not create '$name' in $WS."
    fi
    return 1
  fi
  cd "$WS/$name" || { menu_error "Created '$name' but could not enter it."; return 1; }
  run_claude
}

SESSIONS_BIN="${CLAUDE_SESSIONS_BIN:-claude-sessions}"
NEWSESS="__NEW__"   # special id for the "new session" row in the unified list

# folder selection -> single page: "New session" + saved sessions (resume)
start_in_dir() {
  cd "$1"
  print_header                          # terminal reset + banner (important when entering directly from a subfolder)
  if ! command -v fzf >/dev/null 2>&1; then
    echo
    echo "  1) New session"
    echo "  2) Continue (resume — pick from history)"
    read -rp "  Choice [1-2, default 1]: " sub
    [ "$sub" = "2" ] && run_claude --resume || run_claude
    return
  fi

  # unified TSV "<id>\t<label>": first row is the new session, followed by saved ones
  local list line id saved
  list="$NEWSESS"$'\t'"•  New session"
  if command -v "$SESSIONS_BIN" >/dev/null 2>&1; then
    saved="$("$SESSIONS_BIN" "$1" | sed 's/\t/\t•  /')"   # • marker before the label, leave the id untouched
    [ -n "$saved" ] && list="$list"$'\n'"$saved"
  fi

  line="$(printf '%s\n' "$list" \
    | fzf --height=60% --reverse --border=rounded --pointer='▶' \
          --color='pointer:208,prompt:208' \
          --delimiter='\t' --with-nth=2 \
          --prompt="$(basename "$1") ▸ " \
          --header='new session or resume · Enter · Esc — back' \
          --preview="[ {1} = $NEWSESS ] && echo '  New session in $1' || $SESSIONS_BIN --preview '$1' {1}" \
          --preview-window='down:45%:wrap' --no-multi)" || line=""
  [ -z "$line" ] && return            # Esc -> back to the folder menu
  id="${line%%$'\t'*}"
  if [ "$id" = "$NEWSESS" ]; then run_claude; else run_claude --resume "$id"; fi
}

# temporary (scratch) session; optional $1 — a note to show before starting
run_scratch() {
  if [ -n "${1:-}" ]; then printf '\033c\n  %s\n' "$1"; sleep 1.5; fi
  cd "$(mktemp -d /tmp/claude-scratch.XXXXXX)"; run_claude
}

# --- mode from argument (claude-box passes the target via the host cwd) ---
#   <no argument>         -> full menu (below)
#   /workspace/<subfolder> -> jump straight to this folder's session picker
#   --scratch ["note"]    -> temporary session (the note is shown before starting)
case "${1:-}" in
  --scratch)     run_scratch "${2:-}" ;;
  /workspace/*)  [ -d "$1" ] && start_in_dir "$1" ;;   # no such folder -> fall through to the full menu
esac

# --- numeric fallback without fzf ---
if ! command -v fzf >/dev/null 2>&1; then
  print_header
  echo "  1) Temporary session (scratch, not saved)"
  echo "  2) Create a new folder in /workspace"
  n=2
  for d in "${dirs[@]}"; do
    n=$((n + 1))
    printf "  %d) Launch claude in %s\n" "$n" "$d"
  done
  bash_opt=$((n + 1))
  printf "  %d) bash in the container\n" "$bash_opt"
  read -rp "  Choice [1-$bash_opt]: " choice
  if [ "$choice" = "1" ]; then
    cd "$(mktemp -d /tmp/claude-scratch.XXXXXX)"; run_claude
  elif [ "$choice" = "2" ]; then
    make_new_dir || exit 1              # message already shown by menu_error
  elif [ "$choice" = "$bash_opt" ]; then
    cd "$WS"; exec bash
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 3 ] && [ "$choice" -le "$n" ]; then
    start_in_dir "${dirs[$((choice - 3))]}"
  else
    echo "  Invalid choice." >&2; exit 1
  fi
  exit 0
fi

# --- fzf menu (in a loop: start_in_dir returns here on Esc — "back") ---
dir_items=()
for d in "${dirs[@]}"; do dir_items+=("•  $d"); done    # folders — same marker, in one unified list

while true; do
  print_header
  choice="$(printf '%s\n' "$SCRATCH" "$NEWDIR" "${dir_items[@]}" "$BASHC" \
    | fzf --height=60% --reverse --border=rounded --pointer='▶' \
          --color='pointer:208,prompt:208' --prompt='▸ ' \
          --header='type — search · ↑↓ — select · Enter · Esc — exit' \
          --no-multi)" || choice=""

  case "$choice" in
    "")          exit 0 ;;                                      # Esc — exit
    "$SCRATCH")  cd "$(mktemp -d /tmp/claude-scratch.XXXXXX)"; run_claude ;;
    "$BASHC")    cd "$WS"; exec bash ;;
    "$NEWDIR")   make_new_dir || continue ;;                    # failed -> message shown, back to the menu
    '•  /'*)     start_in_dir "${choice#•  }" ;;                # "•  /workspace/<dir>"; Esc inside -> here
    *)           echo "  Invalid choice." >&2; exit 1 ;;
  esac
done
