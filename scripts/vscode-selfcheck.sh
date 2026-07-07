#!/usr/bin/env bash
# Host-side acceptance check for VS Code (code-server) claude-box.
# Run ON THE HOST with docker (NOT inside the container): ./scripts/vscode-selfcheck.sh
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

PORT="${VSCODE_PORT:-8080}"
URL="http://localhost:${PORT}/"
pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "== 0. preconditions =="
command -v docker >/dev/null 2>&1 || { echo "docker not found — run on the host"; exit 1; }
[ -f .env ] || { echo ".env not found (cp .env.example .env)"; exit 1; }
ok "docker present, .env in place"

echo "== 1. compose sees the vscode service =="
if docker compose config --services 2>/dev/null | grep -qx vscode; then ok "vscode service present"; else no "vscode service missing"; fi

echo "== 2. start (./claude-box --vscode) =="
./claude-box --vscode
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true)"
  case "$code" in 200|302) break ;; esac
  sleep 1
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true)"
case "$code" in
  200) ok "code-server responds at $URL (200, no password)" ;;
  302) ok "code-server responds at $URL (302 — redirect to login, password enabled)" ;;
  *)   no "code-server does not respond at $URL (code '$code')" ;;
esac

echo "== 3. listens on loopback only (not 0.0.0.0) =="
if command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | grep -q "127.0.0.1:${PORT} " && ok "listening on 127.0.0.1:${PORT}" || echo "  (cannot confirm via ss)"
  ss -ltn 2>/dev/null | grep -qE "(0\.0\.0\.0|\*):${PORT} " && no "ALSO on 0.0.0.0:${PORT} — NOT loopback only!"
else
  echo "  (ss unavailable — skipping)"
fi

echo "== 4. status =="
./claude-box --vscode-status

echo "== 5. stop (./claude-box --vscode-stop) =="
./claude-box --vscode-stop
sleep 1
if curl -s -o /dev/null --max-time 3 "$URL" 2>/dev/null; then
  no "still responding after stop (port open)"
else
  ok "port closed after stop"
fi

echo
echo "== result: passed $pass, failed $fail =="
[ "$fail" -eq 0 ]
