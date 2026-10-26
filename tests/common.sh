# Sourced by the test scripts: loads bin/isardvdi's functions (without running a command) in a
# throwaway config dir, so the tests never touch your real config or secrets. The portal URL
# points at a closed local port: no test talks to a real server.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
mkdir -p "$T/xdg/isardvdi-cli" "$T/helpers"
printf 'URL=https://127.0.0.1:1\nUSERNAME=\nSSH_USER=isard\n' > "$T/xdg/isardvdi-cli/config"
export XDG_CONFIG_HOME="$T/xdg"
# shellcheck disable=SC1090,SC1091
source <(sed -n '1,/^cmd="\${1:-help}"/p' "$REPO/bin/isardvdi" | head -n -1)
set +e
# Keyring items made by the tests are all called "selftest".
trap 'keyring_ok && secret-tool clear service isardvdi-cli item selftest 2>/dev/null; rm -rf "$T"' EXIT

pass=0 fail=0 skipped=0
check() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
ok()    { if "$@" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL (expected ok): $*"; fi; }
bad()   { if ( "$@" ) >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL (expected refusal): $*"; else pass=$((pass+1)); fi; }
skip()  { skipped=$((skipped+1)); echo "skip $1"; }
finish() { echo; echo "passed=$pass failed=$fail skipped=$skipped"; exit $((fail > 0)); }

# A fake JWT with the given claims (the signature is junk: only the server could check it).
b64() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
tok() { printf 'eyJhbGciOiJIUzI1NiJ9.%s.c2lnbmF0dXJl' "$(b64 "$1")"; }
now=$(date +%s)

# Runs the CLI itself in the throwaway config dir. Python stubs stand in for the helpers (the CLI
# runs them with python3): the sign-in one leaves a file, so a test can check it never ran.
printf 'open("%s/SSO_CALLED", "w"); raise SystemExit(1)\n' "$T" > "$T/helpers/sso_login.py"
printf 'raise SystemExit(1)\n' > "$T/helpers/browser_token.py"
chmod 755 "$T/helpers/"*
# A fake curl logs each request (URL and headers) to $T/curl.log. It answers a key creation
# with the key in $T/new-key, if there is one; anything else fails like a network error.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in @/*) cat "\${a#@}" ;; https://*) url=\$a; echo "URL \$a" ;; esac
done >> "$T/curl.log"
if [[ "\$url" == */authentication/api-key && -f "$T/new-key" ]]; then
    printf '{"api_key":"%s"}\n200' "\$(cat "$T/new-key")"; exit 0
fi
exit 7
EOF
chmod 755 "$T/bin/curl"
cli() { PATH="$T/bin:$PATH" ISARDVDI_KEYRING=0 ISARDVDI_SSO_HELPER="$T/helpers/sso_login.py" \
        timeout 60 "$REPO/bin/isardvdi" "$@"; }

REAL_VPN="$HOME/.config/isardvdi-cli/isard-vpn.conf"   # only read, if you have one
