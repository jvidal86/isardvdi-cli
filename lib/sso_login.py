#!/usr/bin/python3
"""SAML (Microsoft Entra) login for the isardvdi CLI. Prints the IsardVDI API JWT on stdout.

Drives the same flow as the web UI: <url>/login -> "Identifica't" -> Microsoft -> back to Isard.
A persistent browser profile keeps Microsoft's single sign-on, so after one interactive login
`--headless` refreshes need no password. The Microsoft password is never stored by this tool;
an optional ISARDVDI_PASSWORD env var is used only to auto-fill the form for the current run.

Exit codes: 0 ok, 2 timeout, 3 browser closed, 4 interactive sign-in needed (headless only).
"""
import argparse
import os
import re
import sys
import time

from playwright.sync_api import sync_playwright

JWT = re.compile(r"^[\w-]+\.[\w-]+\.[\w-]*$")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def visible(page, selector):
    try:
        return page.locator(selector).first.is_visible()
    except Exception:
        return False


def api_token(ctx, base):
    for c in ctx.cookies(base):
        if c["name"] == "authorization" and JWT.match(c["value"]):
            return c["value"]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--user", default="", help="Microsoft account, to pick/fill")
    ap.add_argument("--visible", action="store_true", help="show the browser (interactive login)")
    ap.add_argument("--timeout", type=int, default=0)
    args = ap.parse_args()

    base = args.url.rstrip("/")
    headless = not args.visible
    timeout = args.timeout or (90 if headless else 600)
    password = os.environ.get("ISARDVDI_PASSWORD", "")
    os.makedirs(args.profile, mode=0o700, exist_ok=True)

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            args.profile, headless=headless, viewport={"width": 1100, "height": 800})
        try:
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto(base + "/login", wait_until="networkidle")
            login_btn = page.get_by_role("button", name="Identifica't")
            try:
                login_btn.wait_for(state="visible", timeout=20000)  # the SPA draws it after load
                login_btn.click()
            except Exception:
                pass  # already past the login page (existing session) or layout changed; the loop decides
            if not headless:
                log("Browser opened: sign in with your corporate account"
                    " (accept 'Stay signed in' so later logins are silent).")

            done = set()
            end = time.time() + timeout
            debug = os.environ.get("ISARDVDI_DEBUG")
            last = ""
            while time.time() < end:
                page.wait_for_timeout(1000)  # not time.sleep: that would starve Playwright's event loop
                url = page.url
                if debug and url != last:
                    last = url
                    log("page: " + re.sub(r"[?#].*", "", url))
                    try:
                        page.screenshot(path=debug)
                        log("  controls: " + str([
                            (e.evaluate("e=>e.tagName"), (e.get_attribute("id") or e.get_attribute("name") or e.inner_text()[:30]))
                            for e in page.query_selector_all("input,button,[data-test-id]") if e.is_visible()][:12]))
                    except Exception:
                        pass
                if "login.microsoftonline.com" in url:
                    if args.user and visible(page, f'[data-test-id="{args.user}"]') and "tile" not in done:
                        page.locator(f'[data-test-id="{args.user}"]').first.click()
                        done.add("tile")
                    elif args.user and visible(page, 'input[name="loginfmt"]') and "mail" not in done:
                        page.fill('input[name="loginfmt"]', args.user)
                        page.click("#idSIButton9")
                        done.add("mail")
                    elif password and visible(page, 'input[name="passwd"]') and "pw" not in done:
                        page.fill('input[name="passwd"]', password)
                        page.click("#idSIButton9")
                        done.add("pw")
                    elif headless and not args.user and (
                            visible(page, 'input[name="loginfmt"]') or visible(page, "#tilesHolder")):
                        log("Microsoft asks which account to use: sign in interactively.")
                        return 4
                    elif visible(page, 'input[name="passwd"]') and headless:
                        log("Microsoft asks for the password: run `isardvdi login` for an interactive sign-in.")
                        return 4
                    elif visible(page, "#idBtn_Back") and "kmsi" not in done:
                        # "Stay signed in?" page (localised, so match its No button, not its text)
                        page.click("#idSIButton9")  # "Yes": keep Microsoft SSO for silent refreshes
                        done.add("kmsi")
                elif url.startswith(base) and "/login" not in url and "/authentication" not in url:
                    token = api_token(ctx, base)
                    if token:
                        print(token)
                        return 0
            log("Timed out waiting for the sign-in to finish.")
            return 4 if headless else 2
        except Exception as exc:  # window closed, navigation failed, ...
            log(f"Browser closed or failed: {type(exc).__name__}")
            return 4 if headless else 3
        finally:
            try:
                ctx.close()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
