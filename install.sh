#!/bin/sh
# isardvdi-cli installer (POSIX sh — works piped to sh, bash, dash, ...).
#
#   curl -fsSL https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | sh
#   wget -qO-  https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | sh
#
# Installs the `isardvdi` command into $BIN_DIR and its SSO helper into
# $DATA_DIR. No sudo needed; nothing outside your home directory is touched.
#
# Environment:
#   BIN_DIR=$HOME/.local/bin                 where `isardvdi` goes
#   DATA_DIR=$HOME/.local/share/isardvdi-cli where sso_login.py goes
#   ISARDVDI_REF=main                        branch/tag/commit to install
#   ISARDVDI_INSTALL_DEPS=1                  also pip-install Playwright + Chromium (user site)
set -eu
# Installed code must not be writable by group/others, whatever the caller's umask.
umask 022

REPO="jvidal86/isardvdi-cli"
REF="${ISARDVDI_REF:-main}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DATA_DIR="${DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/isardvdi-cli}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"

info() { printf 'isardvdi-install: %s\n' "$*"; }
err()  { printf 'isardvdi-install: error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = "Linux" ] || err "isardvdi-cli is Linux-only"

if have curl; then
    download() { curl -fsSL -o "$2" "$1"; }
elif have wget; then
    download() { wget -qO "$2" "$1"; }
else
    err "need curl or wget"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

info "downloading ($REF)"
download "$BASE/bin/isardvdi"     "$tmp/isardvdi"      || err "download failed: $BASE/bin/isardvdi"
download "$BASE/lib/sso_login.py" "$tmp/sso_login.py"  || err "download failed: $BASE/lib/sso_login.py"
download "$BASE/lib/browser_token.py" "$tmp/browser_token.py" || err "download failed: $BASE/lib/browser_token.py"
head -1 "$tmp/isardvdi" | grep -q '^#!' || err "downloaded file does not look like a script"

mkdir -p "$BIN_DIR" "$DATA_DIR"
install -m 0755 "$tmp/isardvdi"     "$BIN_DIR/isardvdi"
install -m 0644 "$tmp/sso_login.py" "$DATA_DIR/sso_login.py"
install -m 0644 "$tmp/browser_token.py" "$DATA_DIR/browser_token.py"
info "installed $BIN_DIR/isardvdi and its helpers in $DATA_DIR"

# Dependencies. Playwright (Python) drives the Microsoft SSO sign-in.
missing=""
for c in curl jq python3 ssh; do have "$c" || missing="$missing $c"; done
[ -z "$missing" ] || info "missing tools:$missing  (e.g. sudo apt install curl jq python3 openssh-client)"
info "optional: wireguard-tools (wg-quick) to reach desktops over the IsardVDI VPN"
have secret-tool || info "recommended: libsecret-tools (secret-tool) to keep the API key in the system keyring"
python3 -c 'import cryptography' 2>/dev/null \
    || info "recommended: python3-cryptography, to renew the API key from Chrome/Chromium/Vivaldi/Brave/Edge"

if have python3 && ! python3 -c 'import playwright' 2>/dev/null; then
    if [ "${ISARDVDI_INSTALL_DEPS:-0}" = "1" ]; then
        info "installing Playwright + Chromium for the current user"
        python3 -m pip install --user --break-system-packages playwright \
            || err "pip install playwright failed"
        python3 -m playwright install chromium || err "playwright install chromium failed"
    else
        info "Python 'playwright' not found. Install it with:"
        info "    python3 -m pip install --user --break-system-packages playwright && python3 -m playwright install chromium"
        info "or re-run this installer with ISARDVDI_INSTALL_DEPS=1"
    fi
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) info "note: $BIN_DIR is not on your PATH" ;;
esac
info "next: run 'isardvdi init'"
