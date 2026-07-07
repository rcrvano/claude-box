#!/usr/bin/env bash
# Integration test for the sidecar /search route. Run: bash tests/web-search-route.test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
fail=0
check(){ if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; fail=1; fi; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not found"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

tmp="$(mktemp -d)"
PID=""
cleanup(){ [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

proj="$tmp/projects/-test-proj"; mkdir -p "$proj"
cat > "$proj/sess-alpha.jsonl" <<'EOF'
{"type":"user","message":{"content":"hello WORLD foo"},"timestamp":"2026-06-28T10:00:00Z"}
EOF
reg="$tmp/web-sessions.json"
cat > "$reg" <<'EOF'
{"tok-a":{"token":"tok-a","claudeSessionId":"sess-alpha","cwd":"/x","name":"Alpha","state":"done","tmuxSession":"a-x","lastActivity":1782000000}}
EOF
bin="$tmp/bin"; mkdir -p "$bin"
chmod +x "$ROOT/scripts/web-search.sh" "$ROOT/scripts/web-registry.sh"
ln -sf "$ROOT/scripts/web-search.sh"   "$bin/claude-web-search"
ln -sf "$ROOT/scripts/web-registry.sh" "$bin/claude-web-registry"
export PATH="$bin:$PATH"
export CLAUDE_PROJECTS_DIR="$tmp/projects" CLAUDE_WEB_REGISTRY="$reg"

PORT=7799
WEB_TERMINAL_PORT="$PORT" WEB_TERMINAL_PASSWORD="" node "$ROOT/scripts/web-sidecar.js" >/dev/null 2>&1 &
PID=$!
ok=0
for _ in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:$PORT/search?q=" >/dev/null 2>&1; then ok=1; break; fi
  sleep 0.2
done
check "server up + empty q is []" "[]" "$(curl -s "http://127.0.0.1:$PORT/search?q=")"

out="$(curl -s "http://127.0.0.1:$PORT/search?q=world&scope=prompts")"
check "world count" 1     "$(printf '%s' "$out" | jq 'length')"
check "world token" tok-a "$(printf '%s' "$out" | jq -r '.[0].token')"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
