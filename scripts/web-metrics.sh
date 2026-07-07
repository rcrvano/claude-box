#!/usr/bin/env bash
# One-line host metrics + current Claude session context for the /term footer bar.
# Prints ONE line of JSON. Stateless: we measure cpu via two reads of /proc/stat with a pause.
#   claude-web-metrics            -> host metrics, ctx:null
#   claude-web-metrics --id <tok> -> + session context from its transcript
# /proc fields on Linux are NOT namespaced -> these are HOST values (inside the container too).
set -uo pipefail

token=""
[ "${1:-}" = "--id" ] && token="${2:-}"

# --- load: 1-minute average ---
read -r load _ < /proc/loadavg || load=0
load="${load:-0}"

# --- cpu %: two samples of /proc/stat, busy = total - (idle+iowait) ---
read_cpu() { awk '/^cpu /{idle=$5+$6; tot=0; for(i=2;i<=NF;i++) tot+=$i; print tot, idle; exit}' /proc/stat; }
read -r t1 i1 <<<"$(read_cpu)"
sleep 0.2
read -r t2 i2 <<<"$(read_cpu)"
dt=$(( ${t2:-0} - ${t1:-0} )); di=$(( ${i2:-0} - ${i1:-0} ))
if [ "$dt" -gt 0 ]; then cpu=$(( (100 * (dt - di) + dt/2) / dt )); else cpu=0; fi

# --- mem / swap: /proc/meminfo (KB -> bytes) ---
mt=$(awk '/^MemTotal:/{print $2}'     /proc/meminfo); mt="${mt:-0}"
ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo); ma="${ma:-0}"
st=$(awk '/^SwapTotal:/{print $2}'    /proc/meminfo); st="${st:-0}"
sf=$(awk '/^SwapFree:/{print $2}'     /proc/meminfo); sf="${sf:-0}"
mem_used=$(( (mt - ma) * 1024 )); mem_total=$(( mt * 1024 ))
swap_used=$(( (st - sf) * 1024 )); swap_total=$(( st * 1024 ))

# --- disk: df on METRICS_DISK_PATH (1K blocks -> bytes) ---
dpath="${METRICS_DISK_PATH:-/workspace}"
dfline="$(df -Pk "$dpath" 2>/dev/null | awk 'NR==2{print $2, $4}')"
d_total="${dfline% *}"; d_avail="${dfline#* }"
[ -n "${d_total:-}" ] && [ "$d_total" != "$dfline" ] || { d_total=0; d_avail=0; }
disk_total=$(( ${d_total:-0} * 1024 )); disk_free=$(( ${d_avail:-0} * 1024 ))

# --- session: context, git, spend (only with --id) ---
ctx="null"; gitj="null"; spend="null"
if [ -n "$token" ]; then
  rec="$(claude-web-registry get "$token" 2>/dev/null || true)"
  cid="$(printf '%s' "$rec" | jq -r '.claudeSessionId // empty' 2>/dev/null || true)"
  cwd="$(printf '%s' "$rec" | jq -r '.cwd // empty' 2>/dev/null || true)"

  # git: branch + uncommitted flag for the session cwd (safe.directory='*' — volume owned by another uid)
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    b="$(git -C "$cwd" -c safe.directory='*' rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$b" ]; then
      if [ -n "$(git -C "$cwd" -c safe.directory='*' status --porcelain 2>/dev/null | head -n1)" ]; then dirty=true; else dirty=false; fi
      gitj="$(jq -nc --arg b "$b" --argjson d "$dirty" '{branch:$b, dirty:$d}')"
    fi
  fi

  if [ -n "$cid" ]; then
    f="$(find "$HOME/.claude/projects" -name "$cid.jsonl" 2>/dev/null | head -n1)"
    if [ -n "$f" ] && [ -f "$f" ]; then
      # current window fill — from the last line with usage (cheap, tail)
      ctx="$(tail -c 262144 "$f" 2>/dev/null | grep -a '"usage"' | tail -n1 \
        | jq -c --argjson max "${CLAUDE_CONTEXT_MAX:-null}" '
            (.message.usage // .usage) as $u
            | if ($u|type) == "object"
              then {used: (($u.input_tokens//0)+($u.cache_creation_input_tokens//0)+($u.cache_read_input_tokens//0)),
                    max: $max, model: (.message.model // .model // null)}
              else null end' 2>/dev/null || echo null)"
      [ -n "$ctx" ] || ctx="null"

      # session spend — sum of billed tokens across the WHOLE transcript (input+cache+output).
      # Expensive (we read the whole file) -> cache in /tmp with a 10s TTL, so we don't scan on every poll.
      cache="/tmp/claude-metrics-spend-$token"
      now="$(date +%s)"; cage=99999
      [ -f "$cache" ] && cage=$(( now - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
      if [ "$cage" -lt 10 ]; then
        spend="$(cat "$cache" 2>/dev/null || echo null)"
      else
        spend="$(jq -n 'reduce inputs as $l (0;
          . + (($l.message.usage // {}) | ((.input_tokens//0)+(.cache_creation_input_tokens//0)+(.cache_read_input_tokens//0)+(.output_tokens//0))))' \
          "$f" 2>/dev/null || echo null)"
        [ -n "$spend" ] || spend="null"
        printf '%s' "$spend" > "$cache" 2>/dev/null || true
      fi
      [ -n "$spend" ] || spend="null"
    fi
  fi
fi

# --- assemble JSON ---
jq -nc \
  --argjson load "$load" --argjson cpu "$cpu" \
  --argjson mu "$mem_used" --argjson mt "$mem_total" \
  --argjson su "$swap_used" --argjson stt "$swap_total" \
  --argjson df "$disk_free" --argjson dt "$disk_total" --arg dp "$dpath" \
  --argjson ctx "$ctx" --argjson git "$gitj" --argjson spend "$spend" \
  '{load:$load, cpu:$cpu,
    mem:{used:$mu,total:$mt}, swap:{used:$su,total:$stt},
    disk:{free:$df,total:$dt,path:$dp},
    ctx:$ctx, git:$git, spend:$spend}'
