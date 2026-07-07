#!/usr/bin/env bash
# Entrypoint for the web service: brings up ttyd on loopback with the claude-web-menu landing page.
# Port -> WEB_TERMINAL_PORT (default 7681). If WEB_TERMINAL_PASSWORD is set —
# enable basic-auth (login claude). Listen ONLY on 127.0.0.1.
set -euo pipefail

PORT="${WEB_TERMINAL_PORT:-7681}"
# Listening interface. Defaults to loopback (safe). For external access
# set WEB_TERMINAL_INTERFACE=0.0.0.0 — but ONLY together with WEB_TERMINAL_PASSWORD,
# otherwise anyone on the network gets a writable shell into the container.
IFACE="${WEB_TERMINAL_INTERFACE:-127.0.0.1}"

if [ "$IFACE" != "127.0.0.1" ] && [ -z "${WEB_TERMINAL_PASSWORD:-}" ]; then
  echo "WARNING: ttyd is listening on ${IFACE} WITHOUT a password — an open writable shell exposed to the outside!" >&2
  echo "          Set WEB_TERMINAL_PASSWORD in .env." >&2
fi

# ttyd listens ONLY on loopback on an internal port; the sidecar proxies it outward
# (claude-web-sidecar), which also serves the visual launcher at "/" and /sessions.
# The terminal page lives under /term (ttyd --base-path); the sidecar proxies /term*.
TTYD_PORT="${TTYD_PORT:-7682}"
export TTYD_PORT WEB_TERMINAL_PORT="$PORT" WEB_TERMINAL_INTERFACE="$IFACE"

ttyd_args=(--interface 127.0.0.1 --port "$TTYD_PORT" --writable --url-arg --base-path /term)
if [ -n "${WEB_TERMINAL_PASSWORD:-}" ]; then
  ttyd_args+=(-c "claude:${WEB_TERMINAL_PASSWORD}")    # defense-in-depth; the sidecar gates it too
fi
# Font size (with a custom index it's set in index.html; the flag is for compatibility).
if [ -n "${WEB_TERMINAL_FONT_SIZE:-}" ]; then
  ttyd_args+=(-t "fontSize=${WEB_TERMINAL_FONT_SIZE}")
fi
# Custom frontend (sound/scroll/deep-link). No file -> ttyd's stock frontend.
INDEX="${WEB_TERMINAL_INDEX:-/usr/local/share/claude-web/index.html}"
if [ -f "$INDEX" ]; then
  ttyd_args+=(--index "$INDEX")
fi

# --- HTTPS (self-signed) -> secure context for browser notifications. WEB_TLS=0 -> http ---
WEB_TLS="${WEB_TLS:-1}"
if [ "$WEB_TLS" = "1" ]; then
  cdir="$HOME/.claude/web-certs"; CRT="$cdir/web.crt"; KEY="$cdir/web.key"
  mkdir -p "$cdir" 2>/dev/null || true
  if [ ! -s "$CRT" ] || [ ! -s "$KEY" ]; then
    # best-effort: determine the LAN IP for the SAN. Not fatal if ip(8) is missing or fails
    # (otherwise set -euo pipefail kills the entrypoint before ttyd even starts).
    ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true)"
    san="DNS:localhost,IP:127.0.0.1"
    [ -n "$ip" ] && san="$san,IP:$ip"
    [ -n "${WEB_TLS_SAN:-}" ] && san="$san,$WEB_TLS_SAN"
    if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CRT" -days 3650 \
         -subj "/CN=claude-box" -addext "subjectAltName=$san" 2>/dev/null; then
      echo "claude-box web: self-signed cert generated (SAN=$san)"
    else
      echo "claude-box web: openssl failed — falling back to http" >&2; WEB_TLS=0
    fi
  fi
  if [ "$WEB_TLS" = "1" ] && [ -s "$CRT" ] && [ -s "$KEY" ]; then
    export WEB_TLS_CERT="$CRT" WEB_TLS_KEY="$KEY"
  fi
fi
# Port of the https listener (the sidecar always brings up http on $PORT + https on $TLS_PORT
# if a cert exists). Over http there are no secure features (clipboard/notifications); over https there are.
TLS_PORT="${WEB_TLS_PORT:-8443}"; export WEB_TLS_PORT="$TLS_PORT"

auth_status="${WEB_TERMINAL_PASSWORD:+on}"
echo "claude-box web: http://${IFACE}:${PORT}  (launcher; auth: ${auth_status:-off}; ttyd@127.0.0.1:${TTYD_PORT})"
[ -n "${WEB_TLS_CERT:-}" ] && echo "claude-box web: https://${IFACE}:${TLS_PORT}  (secure: clipboard + notifications)"

# --- Public tunnel, if requested via the claude-box --web --tunnel flag ---
# The backend is chosen automatically: if NGROK_AUTHTOKEN is set -> ngrok; otherwise -> cloudflared
# (TryCloudflare, no token/account). We write the public URL to a file under ~/.claude —
# it is bind-mounted to the host (./home/.claude), from where claude-box reads it.
tunnel_pid=""
mkdir -p "$HOME/.claude" 2>/dev/null || true
TUNNEL_URL_FILE="$HOME/.claude/web-tunnel-url"
: > "$TUNNEL_URL_FILE" 2>/dev/null || true
if [ "${WEB_TUNNEL:-}" = "1" ]; then
  if [ -z "${WEB_TERMINAL_PASSWORD:-}" ]; then
    echo "✗ Tunnel not started: WEB_TERMINAL_PASSWORD is not set — a public shell without a password is not allowed." >&2
  elif [ -n "${NGROK_AUTHTOKEN:-}" ]; then
    ngrok_args=(http "$PORT" --log=stdout)
    [ -n "${NGROK_DOMAIN:-}" ] && ngrok_args+=(--domain="$NGROK_DOMAIN")
    echo "claude-box web: starting ngrok -> http://127.0.0.1:${PORT}"
    ngrok "${ngrok_args[@]}" &          # the token is taken from NGROK_AUTHTOKEN
    tunnel_pid=$!
    # grab the public URL from ngrok's local API and write it to the file
    ( for _ in $(seq 1 40); do
        u="$(curl -fsS http://localhost:4040/api/tunnels 2>/dev/null \
             | grep -o '"public_url":"https:[^"]*"' | head -n1 | cut -d'"' -f4)"
        [ -n "$u" ] && { printf '%s\n' "$u" > "$TUNNEL_URL_FILE"; break; }
        sleep 0.5
      done ) &
  else
    cf_log="$HOME/.claude/cloudflared.log"
    echo "claude-box web: starting cloudflared (TryCloudflare, no token) -> http://127.0.0.1:${PORT}"
    # --protocol http2: outbound QUIC/UDP 7844 is blocked on some networks (VM/NAT) —
    # cloudflared then retries the QUIC handshake forever and never prints the public URL.
    # TCP/HTTP2 gets through, so we force http2 (cloudflared itself suggests this
    # in its precheck: "Allow outbound QUIC ... or use HTTP2").
    cloudflared tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${PORT}" > "$cf_log" 2>&1 &
    tunnel_pid=$!
    # cloudflared prints the public URL to its log; pull it out and write it to the file.
    # ~60s window: cloudflared buffers output to the file and flushes the URL with a delay.
    ( for _ in $(seq 1 120); do
        u="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$cf_log" 2>/dev/null | head -n1)"
        [ -n "$u" ] && { printf '%s\n' "$u" > "$TUNNEL_URL_FILE"; break; }
        sleep 0.5
      done ) &
  fi
fi

ttyd "${ttyd_args[@]}" claude-web-menu &
ttyd_pid=$!
claude-web-sidecar &          # holds the public port, proxies /term,/ws,/token to ttyd
sidecar_pid=$!

# Graceful shutdown. PREVIOUSLY it was `exec claude-web-sidecar` -> node became PID1,
# and PID1 WITHOUT a handler ignores SIGTERM -> docker stop waited 10s and sent SIGKILL (137),
# hard-killing Claude in tmux mid-write to ~/.claude (loss of settings/session). Now
# bash catches the signal and sends `tmux kill-server` (SIGHUP to the sessions -> Claude gets a chance
# to save state), then takes down ttyd and the sidecar. (init:true in compose forwards SIGTERM here.)
shutdown() {
  trap - TERM INT EXIT
  tmux kill-server 2>/dev/null || true   # SIGHUP to the panes -> Claude flushes state
  sleep 1                                # short pause to allow saving (within the grace period)
  kill "$ttyd_pid" "$sidecar_pid" ${tunnel_pid:+"$tunnel_pid"} 2>/dev/null || true
  : > "$TUNNEL_URL_FILE" 2>/dev/null || true   # clear the stale public URL
  wait 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT EXIT

wait -n "$ttyd_pid" "$sidecar_pid" ${tunnel_pid:+"$tunnel_pid"}   # any of them died -> we wind down
shutdown
