#!/usr/bin/env bash
# Tests for web-search.sh. Run: bash tests/web-search.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail=0
check(){ if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

proj="$tmp/projects/-test-proj"; mkdir -p "$proj"
cat > "$proj/sess-alpha.jsonl" <<'EOF'
{"type":"user","message":{"content":"hello WORLD foo"},"timestamp":"2026-06-28T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"assistant says banana"}]},"timestamp":"2026-06-28T10:00:05Z"}
{"type":"user","message":{"content":[{"type":"tool_result","content":"world tool noise"}]},"timestamp":"2026-06-28T10:00:06Z"}
not a valid json line
{"type":"user","message":{"content":"math a+b=c result"},"timestamp":"2026-06-28T10:00:07Z"}
{"type":"user","message":{"content":"xay regextrap"},"timestamp":"2026-06-28T10:00:08Z"}
{"type":"user","message":{"content":"hi ΜΗΛΟ"},"timestamp":"2026-06-28T10:01:00Z"}
EOF
cat > "$proj/sess-beta.jsonl" <<'EOF'
{"type":"user","message":{"content":"another WORLD here"},"timestamp":"2026-06-28T09:00:00Z"}
EOF
cat > "$proj/orphan.jsonl" <<'EOF'
{"type":"user","message":{"content":"WORLD orphan not in registry"},"timestamp":"2026-06-28T11:00:00Z"}
EOF

reg="$tmp/web-sessions.json"
cat > "$reg" <<'EOF'
{"tok-a":{"token":"tok-a","claudeSessionId":"sess-alpha","cwd":"/test/proj","name":"Alpha","state":"done","tmuxSession":"alpha-x","lastActivity":1782000000},
 "tok-b":{"token":"tok-b","claudeSessionId":"sess-beta","cwd":"/test/proj","name":"Beta","state":"done","tmuxSession":"beta-x","lastActivity":1782000001}}
EOF

bin="$tmp/bin"; mkdir -p "$bin"
chmod +x "$ROOT/scripts/web-search.sh" "$ROOT/scripts/web-registry.sh"
ln -sf "$ROOT/scripts/web-search.sh"   "$bin/claude-web-search"
ln -sf "$ROOT/scripts/web-registry.sh" "$bin/claude-web-registry"
export PATH="$bin:$PATH"
export CLAUDE_PROJECTS_DIR="$tmp/projects"
export CLAUDE_WEB_REGISTRY="$reg"
run(){ claude-web-search "$@"; }

# 1: prompts scope "world" -> alpha + beta (orphan excluded, tool_result excluded), sorted desc
out="$(run world --scope prompts)"
check "world count"        2          "$(printf '%s' "$out" | jq 'length')"
check "world tokens order" "tok-a tok-b" "$(printf '%s' "$out" | jq -r '[.[].token]|join(" ")')"

# 2: assistant-only term hidden under prompts scope
check "banana prompts" 0 "$(run banana --scope prompts | jq 'length')"
# 3: visible under scope all
out="$(run banana --scope all)"
check "banana all count" 1         "$(printf '%s' "$out" | jq 'length')"
check "banana all type"  assistant "$(printf '%s' "$out" | jq -r '.[0].type')"

# 4: non-ASCII (Greek) case-insensitive (query lower, source UPPER), proves bad line was skipped
out="$(run μηλο --scope prompts)"
check "unicode count" 1     "$(printf '%s' "$out" | jq 'length')"
check "unicode token" tok-a "$(printf '%s' "$out" | jq -r '.[0].token')"

# 5: literal (fixed-string) matching, NOT regex
check "literal a+b"  1 "$(run 'a+b' --scope prompts | jq 'length')"   # regex 'a+b' would NOT match "a+b=c"
check "literal x.y"  0 "$(run 'x.y' --scope prompts | jq 'length')"   # regex 'x.y' WOULD match "xay"

# 6: default scope is prompts
check "default scope" 0 "$(run banana | jq 'length')"

# 7: empty query -> []
check "empty query" "[]" "$(run '' --scope prompts)"

# 8: snippet actually contains the matched term
check "snippet has term" "true" "$(run world --scope prompts | jq '.[0].snippet|ascii_downcase|contains("world")')"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
