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
if you want to reach desktops over the VPN. For `console`: `virt-viewer` (SPICE, the default) and,
for `--rdp`, `freerdp3-x11` (or Remmina).

Pin a version with `ISARDVDI_REF=<tag-or-commit>`; change locations with `BIN_DIR` / `DATA_DIR`.

## First run

```sh
isardvdi init      # URL, account hint, default SSH user; opens a browser for the Microsoft sign-in
isardvdi list      # your desktops: name, state, IP, id
```

No password is stored. The browser profile in `~/.config/isardvdi-cli/browser-profile` keeps the
Microsoft SSO so later token refreshes are silent; when Microsoft asks again, run `isardvdi login`.

### Stay logged in on the web: API key

IsardVDI allows **one login session per user**: every time the CLI signs in, your web browser is
logged out (and vice versa). Teachers and other `advanced` users can avoid this with an API key,
which has no session:

```sh
isardvdi apikey create            # one last SAML login; key valid 365 days (--days N for less)
isardvdi apikey status
```

From then on the CLI only uses the key. When it expires, run `apikey create` again.

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
| `deployments` | Deployments you own or co-own |
| `students <deployment>` | A deployment's desktops: student, group, state, IP, id |
| `console <desktop>` / `console <deployment> <student> [--browser\|--rdp]` | Auto-start if needed, then open the console (SPICE by default) |
| `apikey create [--days N]` / `status` / `revoke` | Use an API key instead of SAML logins (see below) |
| `media list`, `media status <name\|id>` | Your media and media shared with you, with download progress |
| `media add <name> <https-url>` | Register an ISO/floppy; the server downloads the URL and the command waits for `Downloaded` |
| `media desktop <media> <name> --os <id>` | New desktop booting from a media (SATA disk by default, for Windows Setup) |
| `media installs [filter]` | OS profile ids for `--os` |
| `template list`, `template create <desktop> <name> [--group G]...` | Make a template from a stopped desktop and share it with groups |

IsardVDI cannot take a file upload: `media add` needs a URL the server can download, for example
a presigned link to an S3 bucket (`aws s3 presign s3://bucket/file.iso --expires-in 604800`).

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
  `browser-profile/` is a saved login; `apikey` acts as you for up to a year. All are created
  mode 600/700 — treat them as secrets.
- IsardVDI does not check API keys against its stored record, so `isardvdi apikey revoke` only
  deletes the local file and that record: a leaked copy keeps working until it expires. Prefer
  a shorter `--days` on shared machines.
- Do not store desktop passwords in the IsardVDI portal (descriptions and credentials are plain text).

## License

[MIT](LICENSE)
