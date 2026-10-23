#!/usr/bin/python3
"""Find the IsardVDI portal's login token in this computer's web browsers. Prints it on stdout.

The portal keeps its login token (a JWT) in a cookie: 'isardvdi_session', or 'authorization' in
older versions. The token belongs to the browser's own session, so the CLI can create or renew
an API key with it without a new login, which would log the browser out (IsardVDI allows one
login session per user).

Supported: Firefox (cookies are stored in clear) and Chromium-based browsers (Chrome, Chromium,
Vivaldi, Brave, Edge), whose cookies are encrypted with a key kept in KWallet or the Secret
Service keyring. Under WSL, also the Windows user's Firefox. Only the portal's cookies are read
and decrypted. KWallet may ask once whether to allow "isardvdi-cli" to read the browser's key.

Exit codes: 0 found, 1 no valid token in any browser (the portal may not be open: the browser
only refreshes the token while a portal tab is open), 2 usage error.
"""
import argparse
import base64
import glob
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse

COOKIE_NAMES = ("isardvdi_session", "authorization")
HOME = os.path.expanduser("~")
CONFIG = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")

CHROMIUM_DIRS = [os.path.join(CONFIG, d) for d in (
    "google-chrome", "google-chrome-beta", "chromium", "vivaldi", "vivaldi-snapshot",
    "BraveSoftware/Brave-Browser", "microsoft-edge")] + [
    os.path.join(HOME, "snap/chromium/common/chromium")]
FIREFOX_DIRS = [os.path.join(HOME, d) for d in (
    ".mozilla/firefox", "snap/firefox/common/.mozilla/firefox",
    ".var/app/org.mozilla.firefox/.mozilla/firefox")]
# Where Chromium-based browsers keep their cookie key. Vivaldi uses Chrome's entry.
KWALLET_ENTRIES = [("Chrome Keys", "Chrome Safe Storage"), ("Chromium Keys", "Chromium Safe Storage"),
                   ("Brave Keys", "Brave Safe Storage"), ("Vivaldi Keys", "Vivaldi Safe Storage"),
                   ("Microsoft Edge Keys", "Microsoft Edge Safe Storage")]
LIBSECRET_APPS = ["chrome", "chromium", "vivaldi", "brave", "microsoft-edge"]


def log(msg):
    if os.environ.get("ISARDVDI_DEBUG"):
        print("browser_token: " + msg, file=sys.stderr)


def claims(tkn):
    try:
        p = tkn.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except Exception:
        return None


def usable(tkn, user_id):
    """A portal login token (not an API key), valid for at least another minute, for user_id."""
    c = claims(tkn)
    if not isinstance(c, dict):
        return False
    data = c.get("data") or {}
    return (c.get("type") in (None, "", "login")
            and c.get("session_id") != "api-key"
            and isinstance(c.get("exp"), (int, float)) and c["exp"] > time.time() + 60
            and (not user_id or data.get("user_id") == user_id))


def rows(db_path, wal_suffixes, sql, args):
    """Run a query on a copy of a browser database (the browser may hold it locked). Returns the
    rows and, for Chromium, the database version. The copy holds every cookie, so it lives in a
    private directory (mode 700) and is deleted at once."""
    base = os.environ.get("XDG_RUNTIME_DIR") or None
    with tempfile.TemporaryDirectory(dir=base) as tmp:
        copy = os.path.join(tmp, "db")
        shutil.copyfile(db_path, copy)
        for s in wal_suffixes:
            if os.path.exists(db_path + s):
                shutil.copyfile(db_path + s, copy + s)
        con = sqlite3.connect(copy)
        try:
            version = con.execute("SELECT value FROM meta WHERE key='version'").fetchone() \
                if "encrypted_value" in sql else None
            return con.execute(sql, args).fetchall(), int(version[0]) if version else 0
        finally:
            con.close()


def windows_firefox_dirs():
    """Under WSL, the Windows user's Firefox profiles (Firefox doesn't encrypt cookies; Chrome and
    Edge on Windows do, with a key Linux can't use, and lock the file). Best effort: Firefox may
    hold the file locked too."""
    if not (os.environ.get("WSL_DISTRO_NAME") or os.path.exists("/proc/sys/fs/binfmt_misc/WSLInterop")):
        return []
    try:
        cwd = "/mnt/c" if os.path.isdir("/mnt/c") else None  # cmd.exe refuses a Linux cwd
        appdata = subprocess.run(["cmd.exe", "/d", "/c", "echo %APPDATA%"], cwd=cwd,
                                 capture_output=True, text=True, timeout=15).stdout.strip()
        if not appdata or "%" in appdata:
            return []
        path = subprocess.run(["wslpath", "-u", appdata], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [os.path.join(path, "Mozilla", "Firefox", "Profiles")] if path else []


def firefox_tokens(hosts):
    for d in FIREFOX_DIRS + windows_firefox_dirs():
        for db in glob.glob(os.path.join(d, "*", "cookies.sqlite")):
            try:
                found, _ = rows(db, ("-wal",),
                                "SELECT value FROM moz_cookies WHERE host IN (?, ?) AND name IN (?, ?)",
                                (*hosts, *COOKIE_NAMES))
            except Exception as exc:
                log(f"{db}: {type(exc).__name__}")
                continue
            for (value,) in found:
                yield value


def secret_lookup(*attrs):
    try:
        out = subprocess.run(["secret-tool", "lookup", *attrs], capture_output=True, timeout=10)
        return out.stdout.rstrip(b"\n") if out.returncode == 0 and out.stdout else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def kwallet_passwords():
    for n in ("6", "5"):
        dest, path = f"org.kde.kwalletd{n}", f"/modules/kwalletd{n}"

        def call(method, *args):
            out = subprocess.run(["gdbus", "call", "--session", "--dest", dest, "--object-path", path,
                                  "--method", "org.kde.KWallet." + method, *args],
                                 capture_output=True, text=True, timeout=60)
            return out.stdout.strip() if out.returncode == 0 else None

        try:
            res = call("open", "kdewallet", "0", "isardvdi-cli")  # gdbus prints (1234,)
        except (OSError, subprocess.TimeoutExpired):
            continue
        m = re.fullmatch(r"\((?:int32 )?(-?\d+),\)", res or "")
        if not m or int(m.group(1)) < 0:
            continue
        for folder, key in KWALLET_ENTRIES:
            res = call("readPassword", m.group(1), folder, key, "isardvdi-cli")
            # gdbus prints ('value',); a missing entry is ('',)
            v = re.fullmatch(r"\('([^'\\]+)',\)", res or "")
            if v:
                yield v.group(1).encode()
        return


def chromium_keys():
    """Candidate AES keys for 'v11' cookies, then the fixed 'v10' one (no keyring)."""
    seen = set()
    passwords = list(kwallet_passwords())
    for app in LIBSECRET_APPS:
        for schema in ("chrome_libsecret_os_crypt_password_v2", "chrome_libsecret_os_crypt_password_v1"):
            pw = secret_lookup("xdg:schema", schema, "application", app)
            if pw:
                passwords.append(pw)
    for pw in passwords:
        if pw not in seen:
            seen.add(pw)
            yield hashlib.pbkdf2_hmac("sha1", pw, b"saltysalt", 1, 16)


def chromium_decrypt(enc, host_key, version, keys):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    prefix, body = enc[:3], enc[3:]
    if prefix == b"v10":
        keys = [hashlib.pbkdf2_hmac("sha1", b"peanuts", b"saltysalt", 1, 16)]
    elif prefix != b"v11":
        return None
    for key in keys:
        dec = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).decryptor()
        raw = dec.update(body) + dec.finalize()
        pad = raw[-1] if raw else 0
        if not 1 <= pad <= 16:
            continue
        raw = raw[:-pad]
        # Since database version 24 the value starts with SHA-256(host).
        if version >= 24 and raw[:32] == hashlib.sha256(host_key.encode()).digest():
            raw = raw[32:]
        try:
            return raw.decode()
        except UnicodeDecodeError:
            continue
    return None


def chromium_tokens(hosts):
    dbs = []
    for d in CHROMIUM_DIRS:
        for profile in glob.glob(os.path.join(d, "*")):
            for name in ("Network/Cookies", "Cookies"):
                if os.path.isfile(os.path.join(profile, name)):
                    dbs.append(os.path.join(profile, name))
                    break
    if not dbs:
        return
    try:
        import cryptography  # noqa: F401  (python3-cryptography)
    except ImportError:
        log("python3-cryptography is missing: Chromium-based browsers skipped")
        return
    keys = None
    for db in dbs:
        try:
            found, version = rows(db, ("-journal", "-wal"),
                                  "SELECT host_key, encrypted_value, value FROM cookies "
                                  "WHERE host_key IN (?, ?) AND name IN (?, ?)",
                                  (*hosts, *COOKIE_NAMES))
        except Exception as exc:
            log(f"{db}: {type(exc).__name__}")
            continue
        for host_key, enc, value in found:
            if value:
                yield value
            elif enc:
                if keys is None:
                    keys = list(chromium_keys())  # only once, and only if a cookie needs it
                tkn = chromium_decrypt(bytes(enc), host_key, version, keys)
                if tkn:
                    yield tkn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="the portal, https://host")
    ap.add_argument("--user-id", default="", help="only accept tokens of this IsardVDI user")
    args = ap.parse_args()
    host = urlparse(args.url).hostname
    if not host:
        return 2
    hosts = (host, "." + host)
    best = None
    for source in (firefox_tokens, chromium_tokens):
        try:
            for tkn in source(hosts):
                if usable(tkn, args.user_id) and (best is None or claims(tkn)["exp"] > claims(best)["exp"]):
                    best = tkn
        except Exception as exc:  # one broken browser must not hide the others
            log(f"{source.__name__}: {type(exc).__name__}")
    if not best:
        return 1
    print(best)
    return 0


if __name__ == "__main__":
    sys.exit(main())
