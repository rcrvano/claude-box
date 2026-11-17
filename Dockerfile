FROM node:22-slim

# UTF-8 locale (C.UTF-8 is built into glibc, the locales package isn't needed) — otherwise tmux/fzf
# in the web terminal break Cyrillic (show "_") and box-drawing characters.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Base utilities + git/PR + DB clients (psql, mysql, redis-cli) + GitHub CLI + Claude Code.
# The node user (uid 1000) already exists in the image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git git-lfs openssh-client ca-certificates curl less jq ripgrep gnupg fzf vim \
      postgresql-client default-mysql-client redis-tools tmux iproute2 \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code \
 && mkdir -p /home/node/.claude /workspace \
 && chown -R node:node /home/node /workspace

# Grafana MCP (mcp-grafana) — a Go binary for MCP (Loki/Prometheus/dashboards).
# Credentials are taken from ENV (GRAFANA_URL + GRAFANA_SERVICE_ACCOUNT_TOKEN), see claude-defaults/mcp.json.
# The version is pinned (rather than latest via api.github.com) — otherwise rate-limit/504 from the GitHub API breaks the build.
ARG MCP_GRAFANA_VERSION=v0.16.0
RUN curl -fsSL --retry 5 --retry-all-errors "https://github.com/grafana/mcp-grafana/releases/download/${MCP_GRAFANA_VERSION}/mcp-grafana_Linux_x86_64.tar.gz" \
      | tar -xz -C /usr/local/bin mcp-grafana \
 && chmod +x /usr/local/bin/mcp-grafana

# ttyd — web terminal (static x86_64 binary from GitHub releases), see docs/.../web-terminal.
# The version is pinned for the same reason as mcp-grafana above.
ARG TTYD_VERSION=1.7.7
RUN curl -fsSL --retry 5 --retry-all-errors "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
      -o /usr/local/bin/ttyd \
 && chmod +x /usr/local/bin/ttyd

# ngrok v3 — public tunnel to the web terminal (see --tunnel). A static binary
# from the official CDN; the version is pinned for the same reason as ttyd/mcp-grafana above.
ARG NGROK_VERSION=3.18.4
RUN curl -fsSL --retry 5 --retry-all-errors "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v${NGROK_VERSION}-stable-linux-amd64.tgz" \
      | tar -xz -C /usr/local/bin ngrok \
 && chmod +x /usr/local/bin/ngrok

# cloudflared — token-free tunnel backend (TryCloudflare). Used by default
# when NGROK_AUTHTOKEN is not set. We pull latest: TryCloudflare requires a recent build,
# and cloudflared is backward compatible (we run it with --no-autoupdate).
RUN curl -fsSL --retry 5 --retry-all-errors "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
      -o /usr/local/bin/cloudflared \
 && chmod +x /usr/local/bin/cloudflared

# Trust for the TLS proxy certificate(s): put your .crt in certs/ (see README).
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

# Startup menu (folder/session selection) + session list helper for the resume picker
COPY scripts/menu.sh /usr/local/bin/claude-launch
COPY scripts/sessions.js /usr/local/bin/claude-sessions
RUN chmod +x /usr/local/bin/claude-launch /usr/local/bin/claude-sessions

# Web terminal: ttyd launcher + landing picker for tmux sessions
COPY scripts/web-serve.sh /usr/local/bin/claude-web-serve
COPY scripts/web-menu.sh /usr/local/bin/claude-web-menu
COPY scripts/web-registry.sh /usr/local/bin/claude-web-registry
COPY scripts/web-sidecar.js /usr/local/bin/claude-web-sidecar
COPY scripts/web-metrics.sh /usr/local/bin/claude-web-metrics
COPY scripts/web-preview.sh /usr/local/bin/claude-web-preview
COPY scripts/web-search.sh /usr/local/bin/claude-web-search
RUN chmod +x /usr/local/bin/claude-web-serve /usr/local/bin/claude-web-menu \
      /usr/local/bin/claude-web-registry /usr/local/bin/claude-web-sidecar \
      /usr/local/bin/claude-web-metrics /usr/local/bin/claude-web-preview \
      /usr/local/bin/claude-web-search

# Web chat: Claude Agent SDK + ws for the HTML chat mode of the launcher (claude-web-chat.js,
# loaded by the sidecar). Kept in its own prefix, versions pinned like the binaries above.
ARG CLAUDE_AGENT_SDK_VERSION=0.3.326
ARG WS_VERSION=8.18.0
RUN mkdir -p /opt/claude-web-chat && cd /opt/claude-web-chat \
 && echo '{"name":"claude-web-chat","private":true}' > package.json \
 && npm install --omit=dev --no-audit --no-fund \
      "@anthropic-ai/claude-agent-sdk@${CLAUDE_AGENT_SDK_VERSION}" "ws@${WS_VERSION}" \
 && npm cache clean --force
COPY scripts/web-chat.js /usr/local/lib/claude-web/web-chat.js

# Custom ttyd frontend (--index): sound on bell, hidden scroll, deep-link.
# xterm is vendored locally (html/vendor) and inlined into a self-contained index.html
# (ttyd serves a SINGLE file; we don't use a CDN — the terminal has shell access).
COPY html/ /opt/claude-web-src/
RUN node /opt/claude-web-src/build-index.js \
      /opt/claude-web-src/index.html /usr/local/share/claude-web/index.html \
 && node /opt/claude-web-src/build-launcher.js \
      /opt/claude-web-src/launcher.html /usr/local/share/claude-web/launcher.html

# Claude completion signals: notifier + tmux config (set-titles -> tab title)
COPY scripts/notify.sh /usr/local/bin/claude-notify
COPY scripts/tmux.conf /etc/tmux.conf
RUN chmod +x /usr/local/bin/claude-notify

# Shared defaults (settings + MCP) — seeded into ~/.claude at startup (see menu.sh)
COPY claude-defaults/ /opt/claude-defaults/

WORKDIR /workspace
USER node
ENTRYPOINT ["/usr/local/bin/claude-launch"]
