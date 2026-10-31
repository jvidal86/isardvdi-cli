#!/usr/bin/env bash
# Regression tests for the security audit's findings (first pass), on fake data only.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
wait_own() { TARGET_ID="$1" TARGET_OWN=1 TARGET_DEP=""; wait_target "$2" 1; }   # wait_target on your own desktop

echo "== 1 exp claim as code (critical)"
for e in "\"HOME[\$(touch $T/PWNED)]\"" "\"1+\$(touch $T/PWNED)\"" "[1]" "null"; do
    tok "{\"exp\":$e,\"type\":\"external\",\"session_id\":\"api-key\"}" > "$APIKEY_FILE"
    cli deployments >/dev/null 2>&1; cli apikey revoke >/dev/null 2>&1
    tok "{\"exp\":$e,\"type\":\"external\",\"session_id\":\"api-key\"}" > "$APIKEY_FILE"
    cli forget >/dev/null 2>&1
done
check "no command ran from exp (get_jwt, revoke, forget)" '[[ ! -e "$T/PWNED" ]]'
check "jwt_exp: string -> nothing"   '[[ -z "$(jwt_exp "$(tok "{\"exp\":\"1+1\"}")")" ]]'
check "jwt_exp: float -> integer"    '[[ "$(jwt_exp "$(tok "{\"exp\":1824197512.7}")")" == 1824197512 ]]'
tok '{"exp":"HOME[1]","type":"external","session_id":"api-key"}' > "$APIKEY_FILE"
out=$(cli list 2>&1)
check "bad-exp key: clear message"   'grep -q "not valid (no expiry date)" <<<"$out"'
check "new_apikey rejects a non-numeric exp" \
    '! ( api_call() { printf "{\"api_key\":\"%s\"}" "$(tok "{\"exp\":\"x\",\"type\":\"external\",\"session_id\":\"api-key\"}")"; }; new_apikey 90 ) 2>/dev/null'
check "new_apikey rejects a login token as key" \
    '! ( api_call() { printf "{\"api_key\":\"%s\"}" "$(tok "{\"exp\":1,\"type\":\"login\",\"session_id\":\"s\"}")"; }; new_apikey 90 ) 2>/dev/null'
check "new_apikey rejects header injection" \
    '! ( api_call() { printf "{\"api_key\":\"a.b.c\\nX-Evil: 1\"}"; }; new_apikey 90 ) 2>/dev/null'
check "new_apikey accepts a real-looking key" \
    '( api_call() { printf "{\"api_key\":\"%s\"}" "$(tok "{\"exp\":1900000000,\"type\":\"external\",\"session_id\":\"api-key\"}")"; }; new_apikey 90 ) >/dev/null 2>&1'

echo "== 2 VPN routes"
vpn() { printf '[Interface]\nAddress = 10.2.0.5/32\nPrivateKey = k=\n[Peer]\nPublicKey = p=\nAllowedIPs = %s\n' "$1"; }
for r in "0.0.0.0/1, 128.0.0.0/1" "::/1, 8000::/1" "0.0.0.0/0" "10.0.0.0/8" "8.8.8.0/24" "10.2.0.0/16, 1.1.1.1/32" "" "10.2.0.0/16;id"; do
    check "rejects AllowedIPs '$r'" '! ( check_vpn_conf "$(vpn "$r")" ) 2>/dev/null'
done
# Pretend the LAN is somewhere else, so these don't depend on this computer's networks.
for r in "10.2.0.0/16" "10.2.0.0/16, 192.168.5.0/24" "172.31.0.0/16"; do
    check "accepts AllowedIPs '$r'" '( local_networks() { echo 192.168.99.0/24; }; check_vpn_conf "$(vpn "$r")" ) 2>/dev/null'
done

echo "== 3 RDP file: only name:type:value lines"
out=$(printf '%s\n' 'full address:s:10.2.0.9' 'gatewayhostname:s:gw:443' '/drive:home,/home/x' '+home-drive' \
      'redirectdrives:i:1' 'use redirection server name:i:0' 'audiomode:i: value:0' | harden_rdp 0)
check "drops /drive and +home-drive"     '! grep -qE "^[/+]" <<<"$out"'
check "keeps normal settings"            'grep -qx "full address:s:10.2.0.9" <<<"$out" && grep -qx "gatewayhostname:s:gw:443" <<<"$out" && grep -qx "use redirection server name:i:0" <<<"$out"'
check "redirections still forced off"    'grep -qx "redirectdrives:i:0" <<<"$out" && ! grep -qx "redirectdrives:i:1" <<<"$out"'

echo "== 4 wrong account (fake Firefox profiles)"
H="$T/home"; mkdir -p "$H/.mozilla/firefox/a" "$H/.mozilla/firefox/b"
mk() { python3 - "$1" "$2" <<'EOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); con.execute("CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT)")
con.execute("INSERT INTO moz_cookies VALUES ('portal.example.cat','isardvdi_session',?)", (sys.argv[2],)); con.commit()
EOF
}
mk "$H/.mozilla/firefox/a/cookies.sqlite" "$(tok "{\"type\":\"login\",\"session_id\":\"s\",\"exp\":$((now+900)),\"data\":{\"user_id\":\"me\",\"name\":\"Me\"}}")"
mk "$H/.mozilla/firefox/b/cookies.sqlite" "$(tok "{\"type\":\"login\",\"session_id\":\"s\",\"exp\":$((now+1800)),\"data\":{\"user_id\":\"other\",\"name\":\"Other\"}}")"
bt() { env -u WSL_DISTRO_NAME HOME="$H" XDG_CONFIG_HOME="$H/.config" python3 -I "$REPO/lib/browser_token.py" --url https://portal.example.cat "$@"; }
bt >/dev/null 2>&1; rc=$?
check "two accounts, no user id -> refuses (exit 3)" '[[ $rc == 3 ]]'
got=$(bt --user-id me 2>/dev/null)
check "with user id -> that account only" '[[ "$(jwt_payload "$got" | jq -r .data.user_id)" == me ]]'

echo "== 5 terminal escapes"
check "sanitize drops C0 and UTF-8 C1"  '[[ "$(sanitize $'"'"'a\e[2Jb\xc2\x9b31mc'"'"')" == "a[2Jb31mc" ]]'
check "desktop_state cleans ESC"        '[[ "$(desktop_state "{\"status\":\"x\\u001b]52;c;QQ==\\u0007y\"}")" != *$'"'"'\e'"'"'* ]]'
check "desktop_ip rejects junk"         '[[ "$(desktop_ip "{\"ip\":\"1.2.3.4;id\"}")" == null && "$(desktop_ip "{\"ip\":\"10.2.0.7\"}")" == 10.2.0.7 ]]'
check "portal_user cleans ESC"          '[[ "$(portal_user "$(tok "{\"data\":{\"name\":\"a\\u001b[2Jb\"}}")")" != *$'"'"'\e'"'"'* ]]'

echo "== 6 server ids"
check "match_one rejects a non-UUID id"  '! ( echo "[{\"id\":\"x{1..9}\",\"name\":\"Foo\"}]" | match_one d foo name ) 2>/dev/null'
check "match_one accepts a UUID"         '[[ $(echo "[{\"id\":\"0cf16815-bffb-449b-8949-6757e049299a\",\"name\":\"Foo\"}]" | match_one d foo name) == 0cf16815-bffb-449b-8949-6757e049299a ]]'
check "match_one survives non-string names" '[[ $(echo "[{\"id\":\"0cf16815-bffb-449b-8949-6757e049299a\",\"name\":42}]" | match_one d 42 name) == 0cf16815-bffb-449b-8949-6757e049299a ]]'

echo "== 7 no orphaned keyring copy"
if keyring_ok; then
    f="$CONF_DIR/selftest"
    printf 'v1' | secret_save selftest "$f"
    had=$([[ -f "$f.in-keyring" ]] && echo yes)
    printf 'v2' | ISARDVDI_KEYRING=0 secret_save selftest "$f"
    check "falling back to a file clears the keyring copy" '[[ $had == yes && ! -f "$f.in-keyring" && -f "$f" ]] && ! secret-tool lookup service isardvdi-cli item selftest >/dev/null 2>&1'
    secret_clear selftest "$f"
else
    skip "keyring copy (no keyring running)"
fi

echo "== 8 ssh options"
check "ForwardAgent/ForwardX11 forced off" 'grep -q "ForwardAgent=no -o ForwardX11=no" "$REPO/bin/isardvdi"'

echo "== 9 robustness"
# Runs in a subshell, so count calls in a file: the first one fails, like a network blip.
desktop_from_list() { echo x >> "$T/calls"; [[ $(wc -l < "$T/calls") -eq 1 ]] && return 75; echo '{"status":"Started","ip":"10.2.0.8"}'; }
sleep() { :; }
got=$(wait_own 0cf16815-bffb-449b-8949-6757e049299a 5 2>/dev/null)
check "wait_target survives one failed poll" '[[ "$got" == 10.2.0.8 ]]'
unset -f sleep desktop_from_list
check "inherited _ISARDVDI_LOGIN_TOKEN is ignored" \
    '! (_ISARDVDI_LOGIN_TOKEN=1 cli list 2>/dev/null; [[ -e "$T/SSO_CALLED" ]])'

check "SAML sign-in never called in any test" '[[ ! -e "$T/SSO_CALLED" ]]'
finish
