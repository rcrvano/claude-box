# Installation on Windows (WSL2 + Docker Desktop)

claude-box is designed for a Linux host. On Windows it runs through **WSL2** (inside Ubuntu) and
**Docker Desktop**. Below is what to install and how to configure it, step by step.

> Linux host: see the main [README](README.md). This file is only about Windows.

## What you need to install

1. **WSL2 + a real Linux distribution.** The service `docker-desktop` distro won't do (it has no `bash`).
   In PowerShell:
   ```powershell
   wsl --install -d Ubuntu
   ```
   At the end you set a Linux login/password (the password is entered "blind"). Verify: `wsl -l -v` —
   `Ubuntu` should be in the list.

2. **Docker Desktop** (WSL2 backend). After installing:
   `Settings → Resources → WSL Integration` → enable the toggle for **Ubuntu** → **Apply & restart**.
   Check in Ubuntu: `docker version` shows both Client and Server.
   In `Settings → General` enable **Start Docker Desktop when you log in** — otherwise, clicking before the
   daemon starts will give `cannot connect to the Docker daemon`.

3. **Windows Terminal** (recommended — proper copy/paste, Unicode):
   ```powershell
   winget install Microsoft.WindowsTerminal
   ```
   Then `Ctrl+,` → **Startup** → **Default terminal application** = **Windows Terminal** → Save.
   After that, even a double-click on a `.bat` opens in it.

## Configuring claude-box

4. **`PROJECT_DIR` in `.env` is a WSL path, not a Windows one.** From inside Ubuntu, Docker doesn't understand
   `C:\...`; it needs `/mnt/c/...`. Example:
   ```env
   PROJECT_DIR=/mnt/c/Users/<user>/Documents/<...>/<workspace>
   ```
   (the path to the **parent** projects folder; don't point it at `claude-box` itself).

5. **Authorization and the rest** — same as in the README: `CLAUDE_CODE_OAUTH_TOKEN`, and if needed
   `HTTPS_PROXY`/`GH_TOKEN` in `.env`.

## Running

6. **The `claude-box.bat` launcher** (sits in the repository root) — double-click it in Explorer.
   It figures out its own folder (`%~dp0`), converts the path to WSL form, and goes one level up
   to show the full workspace menu.

7. **Icon + shortcut** (optional). Once, in PowerShell:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\make-claude-shortcut.ps1"
   ```
   It creates `claude.ico` and a **"Claude Box"** shortcut (in the repo and on the desktop). To pin it to the taskbar:
   right-click the shortcut → *Show more options* → **Pin to taskbar**.

## Quirks and pitfalls

- **`claude-box.bat` must stay pure ASCII.** If the path contains Cyrillic/spaces,
  it's substituted at runtime via `%~dp0` and `wslpath`; `chcp 65001` + Cyrillic inside the `.bat`
  break `cmd`'s own parsing of the file (it starts executing the comments).
- **Distribution name.** The `.bat` hardcodes `wsl -d Ubuntu`. If the distribution is named differently,
  fix that name (find it with: `wsl -l -v`).
- **Docker Desktop must be running** before you click the icon.
- **`network_mode: host`** behaves differently on Docker Desktop than on Linux: access to host resources
  (Tailscale/DB) over the host network may behave differently than on a Linux host.

---

## Build fails: `x509: certificate signed by unknown authority`

> Cross-platform section (Linux/macOS/Windows). A link from the main [README](README.md) leads here.

Symptom — `./claude-box --build` (or `docker compose build`) fails at the image download stage:

```
failed to solve: node:22-slim: failed to authorize: failed to fetch anonymous token:
... proxyconnect tcp: tls: failed to verify certificate:
x509: certificate signed by unknown authority
```

**Cause.** The **host's** Docker daemon reaches the registry through a self-signed TLS proxy (`HTTPS_PROXY`),
but doesn't trust its certificate (`certs/proxy.crt`). The base image (`FROM`) is pulled by the daemon itself — so
trust for the certificate has to be configured on the daemon (or remove the proxy from the daemon, if there's
direct access to the registry; usually there is).

> This is specifically about the **host daemon** that builds the image. The proxy from `.env` is needed for
> Claude→Anthropic already **inside** the container and has nothing to do with the build (the image trusts the
> certificate — it's baked in at the build stage). That's why `claude-box` builds the RUN steps directly, bypassing
> the proxy, and the problem remains only at `FROM` (whose build-args don't cover it).

### Linux (Debian/Ubuntu) — what the project actually runs on

```bash
./scripts/certs-fix.sh        # puts certs/*.crt into the host trust store (update-ca-certificates)
                              # and restarts docker
./claude-box --build
```

⚠️ The script **restarts docker** — other running containers will stop (bring them back up afterwards with
`docker compose up -d` in their project).

If there's direct access to docker.io/github, the proxy on the daemon is redundant altogether; you can remove it
entirely and build directly without the certificate:

```bash
sudo cat /proc/$(pgrep -x dockerd)/environ | tr '\0' '\n' | grep -i proxy   # find the source
# remove the *_PROXY lines from wherever they're found
# (systemd drop-in /etc/systemd/system/docker.service.d/*.conf, EnvironmentFile,
#  /etc/docker/daemon.json → "proxies", or ~/.docker/config.json → "proxies"), then:
sudo systemctl restart docker
./claude-box --build
```

### macOS / Windows (Docker Desktop)

`scripts/certs-fix.sh` **doesn't work** here — there's no `update-ca-certificates`/`systemctl`. Normally it
isn't needed either: Docker Desktop pulls images directly (or through the proxy from **Settings → Resources →
Proxies**) and trusts the root CAs from the OS system store. If the proxy certificate still has to be added:

- **macOS** (trust the certificate in the System keychain, then restart Docker Desktop):
  ```bash
  sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain certs/proxy.crt
  ```
- **Windows** (PowerShell as administrator, then restart Docker Desktop):
  ```powershell
  Import-Certificate -FilePath certs\proxy.crt -CertStoreLocation Cert:\LocalMachine\Root
  ```

> Caveat: claude-box itself is tailored for a **Linux host** (`network_mode: host` for the host's Tailscale,
> `uid 1000` to match permissions on mounts). On Docker Desktop (Mac/Win), host networking and permission
> mapping work differently — there you'll need other tweaks too, not just the certificate.
