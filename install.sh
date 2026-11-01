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

# Everything runs from main(), called on the last line: if the download is cut short, sh
# gets a syntax error instead of running half an installer.
main() {
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
        commit_of() { curl -fsS --max-time 15 -H 'Accept: application/vnd.github.sha' "$1"; }
    elif have wget; then
        download() { wget -qO "$2" "$1"; }
        commit_of() { wget -qO- --timeout=15 --header='Accept: application/vnd.github.sha' "$1"; }
    else
        err "need curl or wget"
    fi

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT INT TERM

    # Pin a branch or tag to its commit: every file then comes from the same version (raw
    # GitHub caches a branch for minutes), and the commit is recorded for 'isardvdi update'.
    case "$REF" in
        *[!0-9a-f]*|"")
            sha="$(commit_of "https://api.github.com/repos/$REPO/commits/$REF" 2>/dev/null)" || sha=""
            case "$sha" in *[!0-9a-f]*) sha="" ;; esac
            [ ${#sha} -ne 40 ] || { REF="$sha"; BASE="https://raw.githubusercontent.com/$REPO/$REF"; } ;;
    esac

    info "downloading ($REF)"
    download "$BASE/bin/isardvdi"     "$tmp/isardvdi"      || err "download failed: $BASE/bin/isardvdi"
    download "$BASE/lib/sso_login.py" "$tmp/sso_login.py"  || err "download failed: $BASE/lib/sso_login.py"
    download "$BASE/lib/browser_token.py" "$tmp/browser_token.py" || err "download failed: $BASE/lib/browser_token.py"
    download "$BASE/lib/secret_clipboard.py" "$tmp/secret_clipboard.py" || err "download failed: $BASE/lib/secret_clipboard.py"
    download "$BASE/lib/secret_qr.py" "$tmp/secret_qr.py" || err "download failed: $BASE/lib/secret_qr.py"
    head -1 "$tmp/isardvdi" | grep -q '^#!' || err "downloaded file does not look like a script"

    mkdir -p "$BIN_DIR" "$DATA_DIR"
    install -m 0755 "$tmp/isardvdi"     "$BIN_DIR/isardvdi"
    install -m 0644 "$tmp/sso_login.py" "$DATA_DIR/sso_login.py"
    install -m 0644 "$tmp/browser_token.py" "$DATA_DIR/browser_token.py"
    install -m 0644 "$tmp/secret_clipboard.py" "$DATA_DIR/secret_clipboard.py"
    install -m 0644 "$tmp/secret_qr.py" "$DATA_DIR/secret_qr.py"
    # The installed version, for 'isardvdi update' and 'isardvdi version'.
    case "$REF" in
        *[!0-9a-f]*) rm -f "$DATA_DIR/installed-commit" ;;
        *) if [ ${#REF} -eq 40 ]; then printf '%s\n' "$REF" > "$DATA_DIR/installed-commit"
           else rm -f "$DATA_DIR/installed-commit"; fi ;;
    esac
    info "installed $BIN_DIR/isardvdi and its helpers in $DATA_DIR"

    # Dependencies. Playwright (Python) drives the Microsoft SSO sign-in.
    missing=""
    for c in curl jq python3 ssh; do have "$c" || missing="$missing $c"; done
    [ -z "$missing" ] || info "missing tools:$missing  (e.g. sudo apt install curl jq python3 openssh-client)"
    info "optional: wireguard-tools (wg-quick) to reach desktops over the IsardVDI VPN"
    info "optional: qrencode, for 'isardvdi apikey qr' (the API key to the phone app as a QR code)"
    have secret-tool || info "recommended: libsecret-tools (secret-tool) to keep the API key in the system keyring"
    python3 -c 'import cryptography' 2>/dev/null \
        || info "recommended: python3-cryptography, to renew the API key from Chrome/Chromium/Vivaldi/Brave/Edge"

    if have python3 && ! python3 -c 'import playwright' 2>/dev/null; then
        # pip >= 23 (Ubuntu 24.04+) refuses --user installs without --break-system-packages;
        # older pip (Ubuntu 22.04) doesn't know that flag.
        pip_flags="--user"
        python3 -m pip install --help 2>/dev/null | grep -q -- --break-system-packages \
            && pip_flags="--user --break-system-packages"
        if [ "${ISARDVDI_INSTALL_DEPS:-0}" = "1" ]; then
            python3 -m pip --version >/dev/null 2>&1 \
                || err "pip is missing: sudo apt install python3-pip, then re-run this installer"
            info "installing Playwright + Chromium for the current user"
            # shellcheck disable=SC2086  # two separate flags
            python3 -m pip install $pip_flags playwright || err "pip install playwright failed"
            python3 -m playwright install chromium || err "playwright install chromium failed"
            info "if the sign-in browser fails to start (fresh Ubuntu/WSL): python3 -m playwright install-deps chromium (asks for sudo)"
        else
            info "Python 'playwright' not found. Install it with:"
            info "    python3 -m pip install $pip_flags playwright && python3 -m playwright install chromium"
            info "or re-run this installer with ISARDVDI_INSTALL_DEPS=1"
        fi
    fi

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) info "note: $BIN_DIR is not on your PATH" ;;
    esac
    [ "${ISARDVDI_UPDATING:-0}" = 1 ] || info "next: run 'isardvdi init'"
}

main "$@"
