<p align="center">
  <img src="site/brand-mark.svg" alt="claude-box" width="84" height="84">
</p>

# claude-box

Isolated execution of **Claude Code** in Docker: access to a single folder only (`/workspace`),
Claude traffic via a foreign TLS proxy, with state and plugins preserved between runs.

> **Windows?** The project targets a Linux host. Installation and running under Windows (WSL2 + Docker
> Desktop, the `claude-box.bat` launcher, an icon) are covered in [INSTALL.md](INSTALL.md).

## Running

```bash
./claude-box           # start the container (or attach to a running one)
./claude-box --build   # rebuild the image and start
./claude-box --install # print how to add claude-box to PATH (changes nothing)
./claude-box --web      # bring up the web terminal (ttyd) at http://localhost:7681
./claude-box --web --tunnel # + publish it externally (cloudflared without a token / ngrok)
./claude-box --web-stop # stop the web terminal
```

`claude-box` is aware of the directory it was launched from (relative to `PROJECT_DIR`):

- **in a project subfolder** (`$PROJECT_DIR/<project>`) — it goes straight to a single-page session picker for that folder: `• New session` + saved sessions for `--resume`;
- **in the root of `PROJECT_DIR`** — the full **menu** (fzf picker: type to search, ↑↓ and Enter): temporary session (scratch) / create a new folder / run `claude` in a subfolder / `bash` in the container;
- **outside `PROJECT_DIR`** — the container isn't mounted there, so a notification is printed and a **temporary** (scratch) session is started.

To call `claude-box` from anywhere, add it to PATH (`./claude-box --install` shows how).
The working folder `/workspace` is set in `.env` via `PROJECT_DIR` — this is the **parent** folder containing projects (its subfolders, newest first, are what appear in the menu).

> If the build fails with `x509: certificate signed by unknown authority`, that's about the proxy
> certificate on the host Docker daemon; for how to fix it on Linux/macOS/Windows see
> [“Build fails: x509…”](INSTALL.md#build-fails-x509-certificate-signed-by-unknown-authority) in INSTALL.md.

## What's already set up inside

- **Claude authentication** — `CLAUDE_CODE_OAUTH_TOKEN` in `.env` (obtained via `claude setup-token`).
- **Proxy** — Claude→Anthropic traffic goes through a foreign TLS proxy (`HTTPS_PROXY`); internal traffic (Tailscale/DB) goes directly (`NO_PROXY`).
- **Settings** — the host's `settings.json` is copied (auto mode, theme, etc.).
- **superpowers plugin** — lives in `home/.claude/plugins/`, active right away.
- **MCP servers** — user-scope, seeded from `claude-defaults/mcp.json` into `~/.claude.json` at startup: `atlassian`, `github`, `sentry`, `context7`, `kubernetes`, `figma`, `playwright`, `grafana`. Remote ones (`atlassian`/`sentry`/`figma`) are authorized once via `/mcp`; `github` takes `GH_TOKEN`, `context7` takes `CONTEXT7_API_KEY`, `grafana` takes `GRAFANA_URL`+`GRAFANA_SERVICE_ACCOUNT_TOKEN` from `.env`.
- **git** — identity set in `home/.gitconfig`.
- **Completion signals** — when Claude finishes a response (or is waiting for input/permission), a bell rings and the tab title changes to `✅/❓/⏳ <session>`; from another tab you can see which Claude has become free. To disable — `CLAUDE_NOTIFY_DISABLE=1` in `.env` (hooks already seeded remain until you manually clear `home/.claude/settings.json`).
- **Web terminal** — `claude-box --web` brings up ttyd on `127.0.0.1:7681`; the browser opens a picker of tmux sessions (different tabs = different claude sessions, which survive closing the tab). Port/password — `WEB_TERMINAL_PORT` / `WEB_TERMINAL_PASSWORD` in `.env`. Several concurrent sessions share `~/.claude.json` (a shared `./home`), the seed is serialized via flock, but simultaneous active work in the same folder/session from different tabs is not recommended.
- **Public access from your phone** — `claude-box --web --tunnel` brings up the web terminal and publishes it externally (the tunnel runs inside the container), printing a public `https://` address — connect from your mobile anywhere. The backend is chosen automatically: by default **cloudflared** (TryCloudflare — **no token and no account**, a random `*.trycloudflare.com`); if `NGROK_AUTHTOKEN` is set in `.env`, it goes through **ngrok** (optional `NGROK_DOMAIN` for a permanent address). In any case **`WEB_TERMINAL_PASSWORD` is mandatory** — without it the tunnel won't come up (the web terminal stays local); a public shell without a password is not allowed. The tunnel points at the sidecar's http port (`WEB_TERMINAL_PORT`), but the public URL is still `https` (TLS is terminated by the tunnel provider) — so notifications and clipboard work in the phone's browser. It's torn down together with `--web-stop`.

---

## How to get a `GH_TOKEN` (for `gh` — creating PRs, etc.)

`gh` (GitHub CLI) requires a token to work. The simplest way is to set it via the
`GH_TOKEN` variable in `.env` (it's picked up automatically, so `gh auth login` isn't needed).

### Classic token

1. **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
   → **Generate new token (classic)**.
   Direct creation link: <https://github.com/settings/tokens/new>
   (list of all tokens: <https://github.com/settings/tokens>).
2. **Note** — a name (e.g. `claude-box`), **Expiration** — the lifetime.
3. Check the scopes:
   - ✅ **`repo`** — the whole block (Full control of private repositories). This is enough: pushing branches + creating PRs.
   - Everything else (read:org, workflow, packages, admin, gist, user, delete_repo, etc.) is **not needed** — leave it unchecked.
4. **Generate token** → copy it (it starts with `ghp_…`).
5. If your organization has SSO enabled — click **Enable SSO / Authorize** next to the token.

### Set the token

Open `.env`, uncomment the line and paste the token:

```env
GH_TOKEN=ghp_xxx
```

Restart the container — and `gh` is ready:

```bash
./claude-box
# inside:
gh auth status     # should show "Logged in ... (GH_TOKEN)"
gh pr create ...
```

> Alternative without `GH_TOKEN`: run `gh auth login` once inside the container —
> the authorization is saved in `home/.config/gh` and survives restarts.

### Token security

- The token lives in `.env` (permissions `600`) — this file **must not be committed** or shown.
- Use minimal permissions and a shorter lifetime.
- If the token leaks — revoke it on the same GitHub page and generate a new one.

---

## Connecting to JIRA (Atlassian MCP)

Jira/Confluence connect via Atlassian's official remote MCP server.

Authorization — **once**:

1. Start the container: `./claude-box`
2. In Claude type `/mcp` → choose **atlassian** → **Authenticate**.
3. Claude will show an OAuth link — open it in a browser, log in to Atlassian, grant access.
4. The authorization is saved in the passed-through `home/` (`~/.claude`) — no need to log in again on restarts.

**Check:** `/mcp` shows `atlassian — connected`; you can ask Claude to search/read/comment on Jira issues.

---

Build failing with `x509: certificate signed by unknown authority`? That's about the host
Docker daemon trusting the proxy certificate — the analysis and fixes (Linux/macOS/Windows) are in
[INSTALL.md → “Build fails: x509…”](INSTALL.md#build-fails-x509-certificate-signed-by-unknown-authority).
