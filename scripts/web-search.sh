#!/usr/bin/env bash
# Search through session history. Prints a JSON array of results to stdout.
#   claude-web-search <query> [--scope prompts|all]
# Source: JSONL sessions in $CLAUDE_PROJECTS_DIR (default ~/.claude/projects).
# Pipeline: rg emits MATCHED LINES (not files!) -> grep narrows by event type
# (cheap, no parsing) -> a single jq parses only those lines (extracting text of
# the right type, exact unicode case-insensitive LITERAL content match +
# snippet) -> join with the registry. The output contains only sessions present in
# the registry (a token is needed to open a session from the launcher).
# PERFORMANCE: the bottleneck is JSON parsing in jq, not rg. That's why jq sees
# ONLY the lines matched by the query (rg) and filtered by type (grep), not the
# whole corpus. Specific queries -> instant. Frequent short substrings over a
# large corpus can still take seconds (acceptable: debounce on the frontend +
# increased sidecar timeout).
set -uo pipefail

q="${1:-}"; shift || true
scope="prompts"
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) scope="${2:-prompts}"; shift 2 || break;;
    *) shift;;
  esac
done
[ "$scope" = "all" ] || scope="prompts"

PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
LIMIT="${CLAUDE_WEB_SEARCH_LIMIT:-100}"
case "$LIMIT" in (*[!0-9]*|'') LIMIT=100;; esac   # non-numeric value -> default, otherwise the final jq would fail

[ -n "$q" ] || { printf '[]'; exit 0; }
[ -d "$PROJECTS" ] || { printf '[]'; exit 0; }

# The query is treated LITERALLY: escape regex metacharacters for jq test/match.
qre="$(printf '%s' "$q" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"

# Map sessionId -> {token,name} from the registry (for join and filtering by token presence).
regmap="$(claude-web-registry list 2>/dev/null \
  | jq -c 'map({key:.claudeSessionId, value:{token:.token, name:.name}}) | from_entries' 2>/dev/null)"
[ -n "$regmap" ] || regmap='{}'

# Step 1: rg emits MATCHED LINES with the filename, the name/line separator is NUL
# (--null) so that colons in JSON don't break parsing. rg if available, else grep.
search_lines() {
  if command -v rg >/dev/null 2>&1; then
    rg --null -i -F --no-heading --with-filename --glob '*.jsonl' -- "$q" "$PROJECTS" 2>/dev/null
  else
    grep -rIiZF --include='*.jsonl' -e "$q" "$PROJECTS" 2>/dev/null
  fi
}

# Step 2: cheap narrowing by event type WITHOUT parsing JSON — discard lines
# that are clearly of the wrong type (for prompts this includes large assistant lines).
type_prefilter() {
  # -a: the input contains NUL separators (rg --null); without it grep would treat the
  # stream as binary and emit "Binary file matches" instead of the lines themselves.
  if [ "$scope" = "all" ]; then
    grep -aE '"type":"(user|assistant)"'
  else
    grep -aF '"type":"user"'
  fi
}

# Step 3: a single jq parses only the lines that made it through. Line format: <path>\0<json>.
# sessionId = filename without .jsonl. Snippet — a window of ±100 codepoints around the 1st match.
search_lines | type_prefilter | jq -cR --arg scope "$scope" --arg qre "$qre" '
  (index("\u0000")) as $z
  | select($z != null)
  | (.[0:$z]) as $path
  | (.[($z+1):]) as $line
  | ($line | fromjson? // empty) as $o
  | $o
  | select(.type=="user" or ($scope=="all" and .type=="assistant"))
  | (.message.content) as $c
  | (if   ($c|type)=="string" then [$c]
     elif ($c|type)=="array"  then [ $c[] | select(.type=="text") | (.text // "") ]
     else [] end) as $parts
  | ($parts | join(" ") | gsub("[\r\n\t]+"; " ")) as $flat
  | select($flat | test($qre; "i"))
  | ($flat | match($qre; "i")) as $m
  | (if $m.offset > 100 then $m.offset - 100 else 0 end) as $st
  | ($m.offset + $m.length + 100) as $en
  | {sessionId: ($path | sub(".*/"; "") | sub("\\.jsonl$"; "")),
     timestamp: (.timestamp // ""), type: .type,
     snippet: ((if $st > 0 then "…" else "" end)
               + $flat[$st:$en]
               + (if $en < ($flat | length) then "…" else "" end))}
' | jq -s --argjson reg "$regmap" --argjson lim "$LIMIT" '
  map(. + ($reg[.sessionId] // {token:null, name:null}))
  | map(select(.token != null))
  | sort_by(.timestamp) | reverse
  | .[0:$lim]
'
exit 0
