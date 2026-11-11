# Porting isardvdi to Go (one program for Linux and Windows)

The bash version (`../bin/isardvdi`) stays until this one has parity. Rule: **a change goes
into `internal/` once and ships on both systems.** OS-specific code lives only in
`internal/fsperm` (file permissions), `internal/secrets/running_*.go` (is a keyring there?)
and, later, `internal/platform/{linux,windows}` (VPN, viewer, clipboard, browser lookup).

Build:  `CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build ./cmd/isardvdi`  (also `386`, `arm64`)
Test:   `go test ./...`  - and the same tests natively on Windows (see "Windows checks").
Try without a real account: `cmd/fakeportal` + `ISARDVDI_CA_FILE` + `PORTAL_JWT`.

## Commands

| command | state | notes |
|---|---|---|
| list, status `<desktop>`, get | done | tested on Linux and native Windows |
| status `<deployment> <student>` | todo | needs deployments |
| init, login | todo | SSO sign-in: see "Sign-in" |
| start, stop, rename, extend | todo | polling rules: `poll`/`wait_target` (hard error stops at once, 5xx/network retries, deadline) |
| ssh, tunnel, viewer, console | todo | Windows: built-in OpenSSH, `mstsc`, virt-viewer |
| vpn, vpn-config, vpn-reload | todo | Windows: WireGuard for Windows (needs administrator); check_vpn_conf rules |
| apikey (create/status/revoke/pull/qr) | todo | `--from-browser`: Firefox + paste fallback on Windows (see below) |
| deployments, deployment, students, bastion | todo | |
| web, schedule | todo | `schedule` uses systemd units on Linux; Windows needs Task Scheduler |
| media, template, forget | todo | |
| update, version | version done | update: replace the binary from GitHub Releases |

## Invariants carried over from the bash tests (each needs a Go test)

Done: C0/C1/DEL stripping (`sanitize`), URL/IP/UUID/id/path validation (`validate`), match by
name incl. non-string names and non-UUID ids (`match`), `exp` claim never evaluated as code
(`auth`), private files written atomically with no temp file left (`config.WriteFile`), secret
store never loses a secret to a half-working keyring and never turns "keyring locked" into "no
key" (`secrets`), tokens only over HTTPS, never follow a redirect, API key / browser token never
trigger a sign-in on 401 (`api`), config parsed never executed (`config`).

Todo (from `tests/test_security.sh`, `test_audit.sh`, `test_reaudit.sh`):
`check_vpn_conf` (accept/refuse list, routes confirmation), RDP file hardening
(`harden_rdp`), SPICE `.vv` hardening, `desktop_state`/`desktop_ip` cleaning at use sites,
ssh option injection (`-oProxyCommand`), `ForwardAgent/ForwardX11=no`, Ctrl-C reaches child
processes, helper file ownership checks, `jwt_exp` float -> integer at every use.

## Sign-in (the riskiest piece) - what is known

Tested on this Windows machine (Edge 157), with throwaway programs and a local page, never the
real portal:
- `chromedp` (v0.23, pipe transport) drives the **installed Edge** headless: no browser download.
- A persistent profile keeps cookies between runs **if the browser is closed cleanly**: use ONE
  browser context, call `chromedp.Cancel(ctx)` on it *first*, then give it a moment to exit.
  Cancelling a derived (timeout) context first, or killing the browser, loses the cookies.
- `chromedp.DefaultExecAllocatorOptions` are an old Puppeteer list; minimal flags work
  (`NoFirstRun`, `NoDefaultBrowserCheck`, `headless`, `ExecPath`, `UserDataDir`).
- Still to do: the real SAML flow (read `../lib/sso_login.py`, it is the spec), the visible
  sign-in window, Chrome/Chromium on Linux, browser discovery order.

## Known limits on Windows

- Chrome/Edge cookies are encrypted with app-bound encryption: `apikey create --from-browser`
  cannot read them. Firefox and the paste-the-cookie fallback are the supported paths.
- The VPN (WireGuard tunnel service) needs administrator rights.
- An unsigned `.exe` triggers SmartScreen until it is code-signed.

## Live-account hazards (read before testing against the real portal)

The portal allows ONE login session and ONE API key per account. A real sign-in from this
program logs the web browser out; `apikey create` stops the key the bash version uses. Test with
a separate `ISARDVDI_CONFIG_DIR`, and never run `start`, `stop`, `apikey create`, `reset-vpn` or
the bastion key against the real portal without deciding to.

## Windows checks (run on a Windows host)

    for p in api auth commands config jsonx match sanitize secrets validate; do
      CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go test -c -o /tmp/$p.test.exe ./internal/$p; done
    # run each .test.exe on Windows with '-test.v' (quote it in PowerShell);
    # ISARDVDI_TEST_KEYRING=1 also tests the real Credential Manager.
