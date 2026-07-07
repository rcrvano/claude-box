#!/usr/bin/env bash
# Entrypoint for the vscode service: code-server on loopback, /workspace folder opened.
# Port -> VSCODE_PORT (default 8080). VSCODE_PASSWORD set -> password login.
# Listen ONLY on 127.0.0.1. Do not print the password to the log.
set -euo pipefail

PORT="${VSCODE_PORT:-8080}"

args=(--bind-addr "127.0.0.1:${PORT}" --disable-telemetry)
if [ -n "${VSCODE_PASSWORD:-}" ]; then
  export PASSWORD="$VSCODE_PASSWORD"
  args+=(--auth password)
else
  args+=(--auth none)
fi

# code-server extensions: install once, idempotently, best-effort (one failure doesn't
# affect the others and doesn't block startup). They live in the mounted home/, so we install at
# runtime (build-time would be overwritten by the mount). Claude first — VS Code here is pointless without it.
exts=(
  anthropic.claude-code          # Claude panel + auto-connect to claude in the terminal
  eamodio.gitlens                # GitLens
  ms-azuretools.vscode-docker    # Docker
  redhat.vscode-yaml             # YAML
  tamasfe.even-better-toml       # TOML
  editorconfig.editorconfig      # EditorConfig
  mikestead.dotenv               # .env highlighting
  dbaeumer.vscode-eslint         # ESLint
  esbenp.prettier-vscode         # Prettier
)
installed="$(code-server --list-extensions 2>/dev/null || true)"
for ext in "${exts[@]}"; do
  if ! printf '%s\n' "$installed" | grep -qix "$ext"; then
    echo "claude-box vscode: installing extension ${ext}…"
    code-server --install-extension "$ext" \
      || echo "claude-box vscode: failed to install ${ext} (install it manually from Open VSX)"
  fi
done

auth_status="${VSCODE_PASSWORD:+on}"
echo "claude-box vscode: http://localhost:${PORT}  (auth: ${auth_status:-off})"
exec code-server "${args[@]}" /workspace
