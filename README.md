# isardvdi-cli

Command-line control of [IsardVDI](https://www.isardvdi.com) virtual desktops through its REST API (v4),
with SAML/Microsoft Entra single sign-on, WireGuard VPN setup and one-command SSH into a desktop.
Built for the Catalan education portal (`elmeuescriptori.gestioeducativa.gencat.cat`, the default),
but any IsardVDI URL works.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | sh
```

Installs `~/.local/bin/isardvdi` and its helpers in `~/.local/share/isardvdi-cli/` (no sudo). To also
install the Python dependency (Playwright + Chromium) in the same step:

```sh
curl -fsSL https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | ISARDVDI_INSTALL_DEPS=1 sh
```

Requirements: `curl`, `jq`, `python3`, `ssh`, Python `playwright` (+ Chromium), and `wireguard-tools`
if you want to reach desktops over the VPN. Recommended: `libsecret-tools` (keeps the API key in the
system keyring) and `python3-cryptography` (renews the key from Chromium-based browsers). For `console`: `virt-viewer` (SPICE, the default) and,
for `--rdp`, `freerdp3-x11` (or Remmina).

Pin a version with `ISARDVDI_REF=<tag-or-commit>`; change locations with `BIN_DIR` / `DATA_DIR`.
Piping a script into `sh` runs whatever the URL serves at that moment. To check first, download
`install.sh`, read it, and run it with `ISARDVDI_REF` set to a full commit hash, which can't be
changed afterwards.

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
isardvdi apikey create --from-browser   # key valid 90 days (--days N, at most 365)
isardvdi apikey status
```

`--from-browser` creates the key with the portal session of the web browser on this computer, so
the browser stays logged in (a key can't create its own replacement, and a Microsoft sign-in would
log the browser out). Have the portal open in your browser when you run it. Firefox and the
Chromium-based browsers (Chrome, Chromium, Vivaldi, Brave, Edge) are read automatically; their
cookie key comes from KWallet or the Secret Service, and KWallet may ask once whether to allow
`isardvdi-cli`. Only the portal's cookie is read. If no session is found, the CLI asks you to paste
the cookie: DevTools (F12) → Application (Firefox: Storage) → Cookies → the portal, value of
`isardvdi_session` (or `authorization`). Easier: add this bookmark once (any name, e.g.
*IsardVDI session*); clicking it on a portal page copies the session to the clipboard:

```
javascript:(()=>{const m=document.cookie.match(/(?:^|;\s*)(?:isardvdi_session|authorization)=([^;]+)/);if(!m){alert('Log in to the IsardVDI portal first, then click this bookmark on a portal page.');return}const t=decodeURIComponent(m[1]);navigator.clipboard.writeText(t).then(()=>alert('IsardVDI session copied. In the terminal run:  isardvdi apikey create --from-browser  and paste it.'),()=>prompt('Copy this (Ctrl+C), then run: isardvdi apikey create --from-browser',t))})()
```

The session then stays in your clipboard, and in clipboard history tools such as Klipper, until
you copy something else: copy something else after pasting it.

From then on the CLI only uses the key, which it keeps in the system keyring. In the key's last 30
days it renews itself the same way, at most once an hour, whenever the portal is open in your
browser. It only reminds you if that keeps failing for two weeks.

### WSL and Ubuntu 22.04

Everything works under WSL (tested with Ubuntu 22.04's jq, curl, Python and FreeRDP 2), with two
differences:

- **No keyring** unless you set one up: the API key is kept in `~/.config/isardvdi-cli/apikey`
  (mode 600, inside the Linux filesystem).
- **Renewal from a Windows browser:** the key renews itself only from the Windows **Firefox**
  (best effort). Chrome and Edge on Windows lock their cookie file and encrypt it with a key Linux
  can't use, so with them, when the reminder appears (last 14 days), click the bookmark above on the
  portal and run `isardvdi apikey create --from-browser`, then paste.

The Microsoft sign-in (`init`, `login`) needs WSLg (Windows 11) to show its browser window, and
`python3 -m playwright install-deps chromium` (it asks for sudo) once on a fresh Ubuntu.

## Commands

| Command | What it does |
|---|---|
| `init` / `login` | Configure / interactive sign-in |
| `list`, `status <name\|id>` | Show desktops / one desktop's JSON |
| `start <name\|id>` | Start and wait for state `Started` with an IP |
| `stop [--force] <name\|id>` | Stop a desktop |
| `rename <name\|id> <new-name> [--restart]` | Rename a desktop; `--restart` stops a running one first and starts it again |
| `extend <name\|id>` | Postpone a started desktop's automatic shutdown |
| `ssh <name\|id> [-l user] [--no-start] [-- ssh-args]` | Auto-start if needed, then SSH in |
| `vpn-config` | Download the WireGuard config, print the `wg-quick` command |
| `vpn-reload` | Rotate keys and bounce the tunnel (**breaks a working tunnel if misused**) |
| `deployments` | Deployments you own or co-own |
| `students <deployment>` | A deployment's desktops: student, group, state, IP, id |
| `console <desktop>` / `console <deployment> <student> [--browser\|--rdp] [--clipboard]` | Auto-start if needed, then open the console (SPICE by default) |
| `apikey create [--from-browser] [--days N]` / `status` / `print` / `revoke` | Use an API key instead of SAML logins (see below) |
| `forget` | Delete every secret stored on this computer (before leaving a shared one) |
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

If ping works but `ssh` hangs at the key exchange, large packets are being dropped on the way:
lower the tunnel MTU with `ISARDVDI_VPN_MTU=1280 isardvdi vpn-config` and restart the tunnel.
On WSL this is the default.

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

- The API key (acts as you for 90 days) and the cached login token are kept in the **system
  keyring** (GNOME Keyring, KWallet) when there is one, else in `~/.config/isardvdi-cli/apikey` and
  `token`. Older versions' files move into the keyring by themselves. Only a keyring that is already
  running is used, so WSL and servers without one keep using the files (`ISARDVDI_KEYRING=0` forces
  that). A key stored in the keyring can't be read over SSH without a desktop session.
- `~/.config/isardvdi-cli/isard-vpn.conf` holds a WireGuard **private key** (it must stay a file:
  `wg-quick` reads it); `browser-profile/` holds your **Microsoft** sign-in, which reaches your whole
  Microsoft account, not only IsardVDI. The CLI keeps these mode 600/700, refuses files owned by
  another user, and fixes looser permissions when it starts.
- On a shared computer, run `isardvdi forget` when you leave: it deletes the API key (and the
  server's record of it), the token, the VPN config and the Microsoft sign-in.
- IsardVDI does not check API keys against its stored record, so `isardvdi apikey revoke` only
  deletes the local key and that record: a leaked copy keeps working until it expires, which is
  why keys last 90 days and renew themselves. Prefer a shorter `--days` on shared machines.
- **What comes from the server is checked before use.** Before `sudo wg-quick` runs the VPN
  config as root, the CLI refuses any setting IsardVDI doesn't send to users (`PostUp` and other
  command hooks, `DNS`, and any network that isn't a private IPv4 network of /16 or smaller or that
  overlaps a network this computer is on, which blocks a disguised default route such as
  `0.0.0.0/1, 128.0.0.0/1` and a takeover of the home router or the LAN's DNS server). The routes
  are remembered the first time; if the server later changes them, you're asked to confirm. IP addresses, viewer URLs and viewer file types
  are validated, and names are stripped of terminal control characters before printing.
- **Consoles share no local devices.** IsardVDI's default RDP file shares your printers, smartcards
  and clipboard with the desktop, and a student controls their own desktop. `console` turns off
  every USB, drive, printer and smartcard redirection, and shares the clipboard only with your
  own desktops (`--clipboard` to share it with a student's, who could then read what you copy).
- `ssh` remembers each desktop's host key under the desktop's id (`HostKeyAlias`), not its VPN IP,
  which IsardVDI reuses. A host key warning therefore means a different machine: don't ignore it.
- Do not store desktop passwords in the IsardVDI portal (descriptions and credentials are plain text).

## Tests

```bash
tests/run.sh            # every test, on this computer
tests/ubuntu-22.04.sh   # the same CLI on Ubuntu 22.04, as WSL runs it (needs Docker)
```

The tests run in a throwaway config dir with fake keys and never contact a server; your config,
API key and VPN files are left alone. If a keyring is running, a few tests store and then delete
an item named `selftest` in it.

## License

[MIT](LICENSE)
