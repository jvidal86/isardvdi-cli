#!/bin/sh
# isardvdi-cli installer (POSIX sh — works piped to sh, bash, dash, ...).
#
#   curl -fsSL https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | sh
#   wget -qO-  https://raw.githubusercontent.com/jvidal86/isardvdi-cli/main/install.sh | sh
#
# Installs the `isardvdi` command into $BIN_DIR and its SSO helper into
# $DATA_DIR. The program itself needs no sudo and stays in your home directory; installing the
# software it depends on (apt packages) is offered separately and does use sudo.
#
# Environment:
#   BIN_DIR=$HOME/.local/bin                 where `isardvdi` goes
#   DATA_DIR=$HOME/.local/share/isardvdi-cli where sso_login.py goes
#   ISARDVDI_REF=main                        branch/tag/commit to install
#   ISARDVDI_INSTALL_DEPS=1                  install what's missing without asking: apt packages (sudo)
#                                            + Playwright and Chromium (pip, for your user)
#   ISARDVDI_INSTALL_DEPS=all                same, plus the optional packages (QR, Qt windows, RDP)
#   ISARDVDI_INSTALL_DEPS=0                  only report what's missing, never install or ask
# Without it, a terminal gets a question before each install (system packages, then Playwright);
# with no terminal nothing is installed and the commands are printed.
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
    # The RDP client's apt name differs by release (freerdp3-x11 on Ubuntu 24.04+, freerdp2-x11 before).
    rdp_pkg() {
        if have apt-cache && apt-cache policy freerdp3-x11 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            echo freerdp3-x11
        else echo freerdp2-x11; fi
    }

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

    # ---- Requirements: check them all, then offer to install what's missing -------------------
    # kind|what to look for|apt package|what it is for.  (py:X = Python module X)
    DEPS="req|curl|curl|talks to the IsardVDI API
req|jq|jq|reads the API's JSON
req|python3|python3|runs the sign-in helpers
req|ssh|openssh-client|isardvdi ssh
rec|secret-tool|libsecret-tools|keeps the API key in the system keyring
rec|py:cryptography|python3-cryptography|renews the API key from Chrome/Chromium/Vivaldi/Brave/Edge
rec|wg-quick|wireguard-tools|the VPN to reach desktops: isardvdi vpn
rec|remote-viewer|virt-viewer|SPICE console: isardvdi console
opt|qrencode|qrencode|isardvdi apikey qr: the API key to the phone app
opt|py:Qt|python3-pyqt5|clipboard and QR windows on a Linux desktop
opt|rdp|$(rdp_pkg)|RDP console: isardvdi console --rdp"

    UPDATING="${ISARDVDI_UPDATING:-0}"
    MODE="${ISARDVDI_INSTALL_DEPS:-}"   # 1/yes: install without asking | all: also the optional ones | 0: only report
    interactive() { [ -t 2 ] && ( : </dev/tty ) 2>/dev/null; }
    ask() {   # ask QUESTION: yes if the user answers so (default yes); no without a terminal
        interactive || return 1
        printf 'isardvdi-install: %s [Y/n] ' "$1" >&2
        read -r ans </dev/tty || return 1
        case "$ans" in ""|y|Y|yes|Yes|YES|s|S|si|Si|sí) return 0 ;; *) return 1 ;; esac
    }
    as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; elif have sudo; then sudo "$@"; else return 127; fi; }
    present() {
        case "$1" in
            py:Qt) python3 -c 'import PyQt6.QtGui' 2>/dev/null || python3 -c 'import PySide6.QtGui' 2>/dev/null \
                       || python3 -c 'import PyQt5.QtGui' 2>/dev/null ;;
            py:*)  have python3 && python3 -c "import ${1#py:}" 2>/dev/null ;;
            rdp)   have xfreerdp3 || have sdl-freerdp3 || have xfreerdp || have sdl-freerdp || have remmina ;;
            *)     have "$1" ;;
        esac
    }
    pw_dir="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
    # Playwright for Python + its Chromium drive the Microsoft sign-in. apt has neither.
    pw_ok() { have python3 && python3 -c 'import playwright' 2>/dev/null; }
    chromium_ok() { ls -d "$pw_dir"/chromium-* >/dev/null 2>&1; }

    # Probe: one line per item (all of them on an install, only the missing ones on an update).
    PKG_REQ="" PKG_REC="" PKG_OPT="" MISSING_REQ=""
    [ "$UPDATING" = 1 ] || info "checking what isardvdi needs ('required' = it won't run without; 'recommended' = most commands; 'optional' = one command):"
    while IFS='|' read -r kind probe pkg why; do
        if present "$probe"; then
            [ "$UPDATING" = 1 ] || info "  ok       $pkg - $why"
        else
            case "$kind" in
                req) PKG_REQ="$PKG_REQ $pkg"; tag="MISSING (required)   " ;;
                rec) PKG_REC="$PKG_REC $pkg"; tag="missing (recommended)" ;;
                *)   PKG_OPT="$PKG_OPT $pkg"; tag="missing (optional)   " ;;
            esac
            info "  $tag $pkg - $why"
        fi
    done <<DEPS_EOF
$DEPS
DEPS_EOF
    NEED_PW=0 NEED_CHROMIUM=0
    if ! pw_ok; then
        NEED_PW=1 NEED_CHROMIUM=1
        info "  MISSING (required)    Python 'playwright' + Chromium - the Microsoft sign-in; not in apt: installed with pip, for your user"
    elif ! chromium_ok; then
        NEED_CHROMIUM=1
        info "  MISSING (required)    Playwright's Chromium - the Microsoft sign-in browser, a ~150 MB download"
    elif [ "$UPDATING" != 1 ]; then
        info "  ok       playwright + Chromium - the Microsoft sign-in"
    fi

    LIBS_HINT="List them with 'python3 -m playwright install-deps --dry-run chromium', then: sudo apt-get install <those packages>"
    pip_flags="--user"
    python3 -m pip install --help 2>/dev/null | grep -q -- --break-system-packages \
        && pip_flags="--user --break-system-packages"   # pip >= 23 (Ubuntu 24.04) needs it; older pip doesn't know it

    APT_LIST="$PKG_REQ$PKG_REC"
    [ "$MODE" = all ] && APT_LIST="$APT_LIST$PKG_OPT"
    if [ "$NEED_PW" = 1 ] && ! { have python3 && python3 -m pip --version >/dev/null 2>&1; }; then
        APT_LIST="$APT_LIST python3-pip"   # needed to install Playwright
    fi
    # shellcheck disable=SC2086  # a list of words
    set -- $APT_LIST; APT_LIST="$*"
    # shellcheck disable=SC2086
    set -- $PKG_OPT; PKG_OPT="$*"

    if [ -z "$APT_LIST$PKG_OPT" ] && [ "$NEED_PW" = 0 ] && [ "$NEED_CHROMIUM" = 0 ]; then
        [ "$UPDATING" = 1 ] || info "everything isardvdi needs is installed."
    elif [ "$UPDATING" = 1 ] || [ "$MODE" = 0 ]; then
        # Report only: say how to get each missing piece.
        [ -z "$APT_LIST" ] || info "install the missing packages:  sudo apt-get install $APT_LIST"
        [ -z "$PKG_OPT" ] || [ "$MODE" = all ] || info "optional:  sudo apt-get install $PKG_OPT"
        if [ "$NEED_PW" = 1 ] || [ "$NEED_CHROMIUM" = 1 ]; then
            info "install the sign-in browser:  python3 -m pip install $pip_flags playwright && python3 -m playwright install chromium"
        fi
        if [ "$UPDATING" = 1 ]; then
            info "or let the installer do it:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh"
        fi
    else
        # 1. System packages, with apt.
        if [ -n "$APT_LIST" ]; then
            if ! have apt-get; then
                info "no apt-get on this system: install these with your package manager: $APT_LIST"
            elif [ -n "$MODE" ] || ask "Install with sudo: apt-get install $APT_LIST ?"; then
                info "running: sudo apt-get install $APT_LIST"
                # shellcheck disable=SC2086  # a list of words
                if as_root apt-get install -y --no-install-recommends $APT_LIST </dev/null \
                   || { info "apt-get failed; trying once more after 'apt-get update'"
                        as_root apt-get update </dev/null && as_root apt-get install -y --no-install-recommends $APT_LIST </dev/null; }
                then info "installed: $APT_LIST"
                else info "WARNING: couldn't install the packages. Run:  sudo apt-get install $APT_LIST"; fi
            else
                info "not installed. Install with:  sudo apt-get install $APT_LIST"
            fi
        fi
        # 2. Playwright (pip, per user) and Chromium.
        if [ "$NEED_PW" = 1 ] || [ "$NEED_CHROMIUM" = 1 ]; then
            if ! have python3; then
                info "python3 is still missing: install it, then run this installer again for Playwright."
            elif [ -n "$MODE" ] || ask "Install Playwright + Chromium for your user (pip, ~150 MB in $pw_dir; then its system libraries with sudo apt-get)?"; then
                pw_fail=0
                if [ "$NEED_PW" = 1 ]; then
                    info "running: python3 -m pip install $pip_flags playwright"
                    # shellcheck disable=SC2086  # two separate flags
                    python3 -m pip install $pip_flags playwright </dev/null || pw_fail=1
                fi
                if [ "$pw_fail" = 0 ]; then
                    info "running: python3 -m playwright install chromium"
                    python3 -m playwright install chromium </dev/null || pw_fail=1
                fi
                if [ "$pw_fail" = 0 ] && have apt-get; then
                    # Chromium's system libraries. Playwright lists the missing ones (a dry run, as
                    # you); only names shaped like Debian packages reach sudo, and sudo runs apt-get
                    # alone: Python never runs as root, so nothing in your user folders can get there.
                    libs=$(python3 -m playwright install-deps --dry-run chromium </dev/null 2>/dev/null \
                        | sed -n 's/^  \([a-z0-9][a-z0-9.+-]*\)$/\1/p' | tr '\n' ' ')
                    # shellcheck disable=SC2086  # a list of words
                    set -- $libs
                    if [ $# -eq 0 ]; then
                        info "no extra system libraries for Chromium to install (if the sign-in browser won't start: $LIBS_HINT)"
                    elif [ $# -gt 200 ]; then
                        info "WARNING: Playwright listed an unexpected number of libraries; not installing them. $LIBS_HINT"
                    else
                        info "running: sudo apt-get install $*  (Chromium's system libraries)"
                        as_root apt-get install -y --no-install-recommends "$@" </dev/null \
                            || info "WARNING: couldn't install Chromium's libraries. $LIBS_HINT"
                    fi
                fi
                [ "$pw_fail" = 0 ] || info "WARNING: Playwright's installation failed. Run:  python3 -m pip install $pip_flags playwright && python3 -m playwright install chromium"
            else
                info "not installed. Install with:  python3 -m pip install $pip_flags playwright && python3 -m playwright install chromium"
            fi
        fi
        # 3. Optional extras are never installed unless asked for.
        if [ "$MODE" != all ] && [ -n "$PKG_OPT" ]; then
            info "optional, only if you want those commands:  sudo apt-get install $PKG_OPT   (or ISARDVDI_INSTALL_DEPS=all)"
        fi
        interactive || [ -n "$MODE" ] || info "(no terminal to ask on: re-run with ISARDVDI_INSTALL_DEPS=1 to install the missing packages automatically)"
    fi

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) info "note: $BIN_DIR is not on your PATH" ;;
    esac
    [ "${ISARDVDI_UPDATING:-0}" = 1 ] || info "next: run 'isardvdi init'"
}

main "$@"
