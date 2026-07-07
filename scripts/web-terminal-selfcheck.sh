#!/usr/bin/env bash
# Host-side acceptance check for the claude-box web terminal (ttyd).
# Run ON THE HOST with docker installed (NOT inside the container).
#   ./scripts/web-terminal-selfcheck.sh
# Runs through: web service present -> start -> port on 127.0.0.1 -> --web-status ->
# optional basic-auth (if WEB_TERMINAL_PASSWORD is set in .env) -> stop.
set -uo pipefail

# repository root (scripts/ -> ..), resilient to symlinks
cd "$(dirname "$(readlink -f "$0")")/.."

PORT="${WEB_TERMINAL_PORT:-7681}"
URL="http://localhost:${PORT}/"
pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "== 0. preconditions =="
command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the host"; exit 1; }
[ -f .env ] || { echo ".env not found (first run: cp .env.example .env)"; exit 1; }
ok "docker present, .env in place"

echo "== 1. docker compose sees the web service =="
if docker compose config --services 2>/dev/null | grep -qx web; then
  ok "web service present"
else
  no "web service missing from compose"
fi

echo "== 2. start the web terminal (./claude-box --web) =="
./claude-box --web
# wait for the port to come up (up to 30s; the first image build may take longer — then re-run)
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true)"
  { [ "$code" = "200" ] || [ "$code" = "401" ]; } && break
  sleep 1
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true)"
case "$code" in
  200) ok "ttyd responds on $URL (HTTP 200, no password)" ;;
  401) ok "ttyd responds on $URL (HTTP 401 — basic-auth enabled)" ;;
  *)   no "ttyd not responding on $URL (code '$code')" ;;
esac

echo "== 3. listens on loopback only (not 0.0.0.0) =="
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q "127.0.0.1:${PORT} "; then
    ok "listening on 127.0.0.1:${PORT}"
  else
    echo "  (could not confirm via ss — check manually)"
  fi
  if ss -ltn 2>/dev/null | grep -qE "(0\.0\.0\.0|\*):${PORT} "; then
    no "ALSO listening on 0.0.0.0:${PORT} — NOT loopback only!"
  fi
else
  echo "  (ss unavailable — skipping interface check)"
fi

echo "== 4. status (./claude-box --web-status) =="
./claude-box --web-status

echo "== 5. basic-auth (if WEB_TERMINAL_PASSWORD is set in .env) =="
PW="$(grep -E '^WEB_TERMINAL_PASSWORD=' .env 2>/dev/null | head -n1 | cut -d= -f2-)"
if [ -n "${PW:-}" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true)"
  [ "$code" = "401" ] && ok "request without login rejected (401)" || no "password is set, but code '$code' (expected 401)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -u "claude:${PW}" "$URL" 2>/dev/null || true)"
  [ "$code" = "200" ] && ok "correct login/password accepted (200)" || no "with correct credentials code '$code' (expected 200)"
else
  echo "  WEB_TERMINAL_PASSWORD is empty — check skipped (set it in .env to test)"
fi

echo "== 6. stop (./claude-box --web-stop) =="
./claude-box --web-stop
sleep 1
# curl exits successfully (code 0) only if it actually connected and got a response;
# connection refused -> non-zero code -> port closed.
if curl -s -o /dev/null --max-time 3 "$URL" 2>/dev/null; then
  no "still responding after stop (port open)"
else
  ok "port closed after stop"
fi

echo
echo "== summary: passed $pass, failed $fail =="
[ "$fail" -eq 0 ]
