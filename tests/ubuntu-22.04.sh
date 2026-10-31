#!/usr/bin/env bash
# The CLI on Ubuntu 22.04 (what WSL usually runs): its older jq, curl, Python, cryptography and
# FreeRDP, and the keyring with and without a D-Bus session. Needs Docker; run it from anywhere:
#   tests/ubuntu-22.04.sh
# It starts an ubuntu:22.04 container with the repo mounted read-only and runs itself inside.
if [[ ! -f /.dockerenv ]]; then
    repo=$(cd "$(dirname "$0")/.." && pwd)
    exec docker run --rm -v "$repo":/src:ro ubuntu:22.04 bash /src/tests/ubuntu-22.04.sh
fi

export DEBIAN_FRONTEND=noninteractive
echo "Installing packages..."
apt-get update -qq >/dev/null
apt-get install -y -qq curl jq python3 python3-cryptography libsecret-tools dbus gnome-keyring \
    freerdp2-x11 xvfb >/dev/null 2>&1
# shellcheck source=common.sh
source /src/tests/common.sh
CLI=/src/bin/isardvdi
load="source $CLI; set +e"

echo "== FreeRDP 2 clipboard syntax"
xvfb-run -a xfreerdp /help 2>/dev/null | grep -E '^\s+[+/-]?clipboard|clipboard ' | head -3

echo "== jq 1.6 / bash 5.1 helpers"
check "JQ_CLEAN strips ESC"   '[[ "$(jq -rn "$JQ_CLEAN"'"'"' "x\u001b[2Jy" | clean'"'"')" == "x?[2Jy" ]]'
check "sanitize"              '[[ "$(sanitize $'"'"'a\eb'"'"')" == ab ]]'
check "jwt_payload"           '[[ "$(jwt_payload "$(tok "{\"exp\":5}")" | jq -r .exp)" == 5 ]]'
check "match_one any()"       '[[ "$(echo "[{\"id\":\"0cf16815-bffb-449b-8949-6757e049299a\",\"name\":\"Foo\"}]" | match_one d foo name)" == 0cf16815-bffb-449b-8949-6757e049299a ]]'
check "vpn allow-list rejects PostUp" '! ( check_vpn_conf $'"'"'[Interface]\nPostUp = x'"'"' ) 2>/dev/null'
check "harden_rdp"            '[[ "$(printf "redirectprinters:i:1\n" | harden_rdp 0 | grep -c ":i:1")" == 0 ]]'
check "harden_vv (GNU sed a)" '[[ "$(printf "[virt-viewer]\nhost=h\n" | harden_vv 0 | sed -n 2p)" == enable-usbredir=0 ]]'

echo "== curl 7.81 takes the CLI's options"
tok "{\"exp\":$((now+80*86400)),\"type\":\"external\",\"session_id\":\"api-key\"}" > "$APIKEY_FILE"
# The real curl, against a closed port: a connection error (exit 7), not an option error.
out=$(ISARDVDI_KEYRING=0 timeout 60 "$CLI" list 2>&1)
check "header from fd + --proto =https" 'grep -q "network error (curl exit 7)" <<<"$out"'

echo "== keyring: no D-Bus session (plain WSL)"
check "no keyring -> files"   '! ( unset DBUS_SESSION_BUS_ADDRESS; keyring_ok )'
echo "== keyring: D-Bus but no running keyring, no gdbus (WSL with systemd)"
start=$SECONDS
out=$(dbus-run-session -- bash -c "$load; keyring_ok && echo USE || echo SKIP" 2>/dev/null)
check "skips a keyring that isn't running, fast" '[[ $out == SKIP && $((SECONDS - start)) -lt 10 ]]'
echo "== keyring: running gnome-keyring (WSL with a keyring set up)"
out=$(dbus-run-session -- bash -c "printf pw | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1; sleep 1
    $load
    keyring_ok && echo USE || echo SKIP
    f=\$CONF_DIR/selftest; printf s3cret | secret_save selftest \$f
    [[ -f \$f.in-keyring ]] && echo IN-KEYRING; [[ \$(secret_load selftest \$f) == s3cret ]] && echo LOADED" 2>/dev/null)
check "uses a running keyring"  'grep -q USE <<<"$out"'
check "stores and loads in it"  'grep -q IN-KEYRING <<<"$out" && grep -q LOADED <<<"$out"'

echo "== browser_token.py on Python 3.10 / cryptography 3.4.8"
python3 -I /src/lib/browser_token.py --url https://portal.example.cat; rc=$?
check "no browsers -> exit 1" '[[ $rc == 1 ]]'
rt=$(python3 -I - <<'EOF'
import sys, hashlib; sys.path.insert(0, "/src/lib")
import browser_token as b
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
host = ".example.cat"; pw = b"wallet-pw"; plain = hashlib.sha256(host.encode()).digest() + b"a.b.c"
key = hashlib.pbkdf2_hmac("sha1", pw, b"saltysalt", 1, 16)
pad = 16 - len(plain) % 16; plain += bytes([pad]) * pad
enc = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).encryptor()
blob = b"v11" + enc.update(plain) + enc.finalize()
print(b.chromium_decrypt(blob, host, 24, [key]))
EOF
)
check "Chromium cookie decrypt round-trip" '[[ "$rt" == a.b.c ]]'

finish
