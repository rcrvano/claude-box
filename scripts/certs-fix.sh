#!/usr/bin/env bash
# certs-fix.sh — make the HOST Docker daemon trust the self-signed cert of the TLS proxy.
#
# Why: dockerd reaches the registry through an overseas proxy (HTTPS_PROXY from .env, TLS on :8443).
# The proxy cert is self-signed and not in the daemon's system trust-store — so pulling the base
# image fails with: "proxyconnect tcp: tls: failed to verify certificate: x509: ... unknown authority".
# The script places certs/*.crt into the system trust and restarts the daemon (Go reads trust only at startup).
#
# NB: the container image trusts the cert anyway (Dockerfile: COPY certs/ + update-ca-certificates).
#     This script is specifically about the HOST daemon that pulls the images.
#
# Usage:
#   ./scripts/certs-fix.sh              # install the cert(s) and restart docker
#   ./scripts/certs-fix.sh --no-restart # only install the cert, without restarting the daemon
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="$REPO/certs"
DEST="/usr/local/share/ca-certificates"
RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

# sudo only if not root
SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

shopt -s nullglob
crts=("$CERTS_DIR"/*.crt)
if [ ${#crts[@]} -eq 0 ]; then
  echo "No .crt files in $CERTS_DIR — add the proxy cert (see README) and retry." >&2
  exit 1
fi

echo "Installing the proxy cert(s) into the system trust-store:"
for crt in "${crts[@]}"; do
  name="claude-box-$(basename "$crt")"
  echo "  + $(basename "$crt") -> $DEST/$name"
  $SUDO install -m 0644 "$crt" "$DEST/$name"
done

$SUDO update-ca-certificates

if [ "$RESTART" -eq 1 ]; then
  echo
  echo "⚠️  Restarting docker — this will stop running containers (live-restore is off)."
  echo "    If there are containers on the host without a restart policy that you need — bring them back up afterwards (docker compose up -d)."
  $SUDO systemctl restart docker
  echo "Done. dockerd has been restarted and now trusts the proxy cert."
else
  echo
  echo "Cert installed. Restart the daemon so it picks up the trust:  $SUDO systemctl restart docker"
fi
