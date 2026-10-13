# isardvdi-cli

Command-line control of [IsardVDI](https://www.isardvdi.com) virtual desktops through its REST API (v4),
with SAML/Microsoft Entra single sign-on, WireGuard VPN setup and one-command SSH into a desktop.
Built for the Catalan education portal (`elmeuescriptori.gestioeducativa.gencat.cat`, the default),
but any IsardVDI URL works.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | sh
```

Installs `~/.local/bin/isardvdi` and `~/.local/share/isardvdi-cli/sso_login.py` (no sudo). To also
install the Python dependency (Playwright + Chromium) in the same step:

```sh
curl -fsSL https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | ISARDVDI_INSTALL_DEPS=1 sh
```

Requirements: `curl`, `jq`, `python3`, `ssh`, Python `playwright` (+ Chromium), and `wireguard-tools`
if you want to reach desktops over the VPN.

Pin a version with `ISARDVDI_REF=<tag-or-commit>`; change locations with `BIN_DIR` / `DATA_DIR`.

## First run

```sh
isardvdi init      # URL, account hint, default SSH user; opens a browser for the Microsoft sign-in
isardvdi list      # your desktops: name, state, IP, id
```

No password is stored. The browser profile in `~/.config/isardvdi-cli/browser-profile` keeps the
Microsoft SSO so later token refreshes are silent; when Microsoft asks again, run `isardvdi login`.

## Commands

| Command | What it does |
|---|---|
| `init` / `login` | Configure / interactive sign-in |
| `list`, `status <name\|id>` | Show desktops / one desktop's JSON |
| `start <name\|id>` | Start and wait for state `Started` with an IP |
| `stop [--force] <name\|id>` | Stop a desktop |
| `ssh <name\|id> [-l user] [--no-start] [-- ssh-args]` | Auto-start if needed, then SSH in |
| `vpn-config` | Download the WireGuard config, print the `wg-quick` command |
| `vpn-reload` | Rotate keys and bounce the tunnel (**breaks a working tunnel if misused**) |

`<name|id>` is an exact UUID or a case-insensitive substring of the desktop name.
See `isardvdi help` for environment variables (`ISARDVDI_START_TIMEOUT`, `SSH_USER`, ...).

## Reaching desktops

Desktops only get an IP if they were started with the **WireGuard** interface. Bring the tunnel up once:

```sh
isardvdi vpn-config                 # prints the exact sudo wg-quick command
sudo wg-quick up ~/.config/isardvdi-cli/isard-vpn.conf
isardvdi ssh my-desktop
```

### Remote control of a Windows desktop over SSH

On the Windows desktop (elevated PowerShell), once:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
# administrators authenticate with this file, not ~\.ssh\authorized_keys
Add-Content C:\ProgramData\ssh\administrators_authorized_keys '<your public key>'
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" "SYSTEM:F"
```

Then from Linux: `isardvdi ssh <desktop> -l Administrator`. The default shell is `cmd.exe`.

## Files and security

- `~/.config/isardvdi-cli/isard-vpn.conf` holds a WireGuard **private key**; `token` is a cached JWT;
  `browser-profile/` is a saved login. All are created mode 600/700 — treat them as secrets.
- Do not store desktop passwords in the IsardVDI portal (descriptions and credentials are plain text).
