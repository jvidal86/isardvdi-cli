#!/usr/bin/env bash
# Regression tests for the second and third audit passes, on fake data only.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
wait_own() { TARGET_ID="$1" TARGET_OWN=1 TARGET_DEP=""; wait_target "$2" 1; }   # wait_target on your own desktop

echo "== 1 VPN networks (the LAN is faked as 192.168.1.0/24 and 10.50.0.0/16)"
local_networks() { printf '192.168.1.0/24\n10.50.0.0/16\n'; }
vpn() { printf '[Interface]\nAddress = %s\nPrivateKey = k=\n[Peer]\nPublicKey = p=\nAllowedIPs = %s\n' "$1" "$2"; }
for r in "192.168.1.1/32" "10.50.0.53/32" "10.50.0.0/16" "10.0.0.0/8" "010.2.0.0/16" "10.2.0.0/16, 0.0.0.0/1" "10.2.0.256/16"; do
    check "AllowedIPs '$r' refused" '! ( check_vpn_conf "$(vpn 10.2.0.5 "$r")" ) 2>/dev/null'
done
for a in "10.0.0.2/1" "192.168.1.7" "8.8.8.8"; do
    check "Address '$a' refused" '! ( check_vpn_conf "$(vpn "$a" 10.2.0.0/16)" ) 2>/dev/null'
done
check "IsardVDI-style config accepted" '( check_vpn_conf "$(vpn 10.2.0.5 10.2.0.0/16)" ) 2>/dev/null'
check "Address with /32 accepted"      '( check_vpn_conf "$(vpn 10.2.0.5/32 10.2.0.0/16)" ) 2>/dev/null'
check "route covering the DNS server refused" '! ( local_networks() { printf "192.168.1.0/24\n10.1.1.1\n"; }; check_vpn_conf "$(vpn 10.2.0.5 "10.2.0.0/16, 10.1.1.0/24")" ) 2>/dev/null'
unset -f local_networks
check "this computer's gateway/DNS are listed" '( source <(sed -n "/^local_networks()/,/^}/p" "$REPO/bin/isardvdi"); local_networks ) | grep -qE "^[0-9]+(\.[0-9]+){3}$"'

echo "== 1b routes remembered; changes need a yes"
two=$'[Interface]\nAddress = 10.2.0.5\nPrivateKey = k=\n[Peer]\nPublicKey = p=\nAllowedIPs = 10.2.0.0/16\nAllowedIPs = 192.168.2.0/24'
peers=$'[Interface]\nAddress = 10.2.0.5\nPrivateKey = k=\n[Peer]\nPublicKey = p=\nAllowedIPs = 10.2.0.0/16\n[Peer]\nPublicKey = q=\nAllowedIPs = 10.3.0.0/16'
check "first 10.x routes: accepted and remembered" '( vpn_routes_confirmed "$(vpn 10.2.0.5 10.2.0.0/16)" ) </dev/null 2>/dev/null && [[ $(cat "$VPN_ROUTES_FILE") == 10.2.0.0/16 ]]'
check "same routes again: accepted"                '( vpn_routes_confirmed "$(vpn 10.2.0.5 10.2.0.0/16)" ) </dev/null 2>/dev/null'
check "changed routes without a terminal: refused" '! ( vpn_routes_confirmed "$(vpn 10.2.0.5 "10.2.0.0/16, 10.9.0.0/16")" ) </dev/null 2>/dev/null'
rm -f "$VPN_ROUTES_FILE"
check "first non-10.x routes without a terminal: refused" '! ( vpn_routes_confirmed "$(vpn 10.2.0.5 192.168.50.0/24)" ) </dev/null 2>/dev/null'
check "two AllowedIPs lines: not silent"     '! ( vpn_routes_confirmed "$two" ) </dev/null 2>/dev/null && [[ ! -f "$VPN_ROUTES_FILE" ]]'
check "two [Peer] sections: not silent"      '! ( vpn_routes_confirmed "$peers" ) </dev/null 2>/dev/null && [[ ! -f "$VPN_ROUTES_FILE" ]]'
check "10.2.0.0/16 + a 10.x /32: not silent" '! ( vpn_routes_confirmed "$(vpn 10.2.0.5 "10.2.0.0/16, 10.1.1.1/32")" ) </dev/null 2>/dev/null'
check "trailing comment doesn't change the routes" '( vpn_routes_confirmed "$(vpn 10.2.0.5 "10.2.0.0/16 # note")" ) </dev/null 2>/dev/null && [[ $(cat "$VPN_ROUTES_FILE") == 10.2.0.0/16 ]] && ( vpn_routes_confirmed "$(vpn 10.2.0.5 10.2.0.0/16)" ) </dev/null 2>/dev/null'

echo "== 2 polling: real deadlines, retry only temporary errors"
sleep() { command sleep 0.01; }
desktop_from_list() { echo x >> "$T/n"; [[ $(wc -l < "$T/n") -le 2 ]] && return 75; echo '{"status":"Started","ip":"10.2.0.8"}'; }
got=$( ( wait_own 0cf16815-bffb-449b-8949-6757e049299a 10 ) 2>/dev/null )
check "two temporary failures, then ready" '[[ "$got" == 10.2.0.8 ]]'
rm -f "$T/n"
desktop_from_list() { echo x >> "$T/n"; return 1; }
( wait_own 0cf16815-bffb-449b-8949-6757e049299a 10 ) >/dev/null 2>&1; rc=$?
check "a hard error (e.g. 401) stops at once" '[[ $rc == 1 && $(wc -l < "$T/n") == 1 ]]'
desktop_from_list() { command sleep 2; return 75; }
start=$SECONDS; ( wait_own 0cf16815-bffb-449b-8949-6757e049299a 4 ) >/dev/null 2>&1; rc=$?
check "slow failing polls respect a 4 s deadline (took $((SECONDS-start)) s, rc $rc)" '[[ $rc == 124 && $((SECONDS-start)) -le 7 ]]'
desktop_from_list() { echo '{"status":"Starting"}'; }
( wait_own 0cf16815-bffb-449b-8949-6757e049299a 2 ) >/dev/null 2>&1; rc=$?
check "plain timeout returns 124" '[[ $rc == 124 ]]'
unset -f sleep desktop_from_list
check "api_call: no answer -> 75 (retry)" \
    '( get_jwt() { echo x; }; api_call GET /x ) >/dev/null 2>&1; [[ $? == 75 ]]'

echo "== 3 Ctrl-C reaches commands under timeout"
out=$(python3 "$REPO/tests/pty_ctrl_c.py" 'x=$(timeout --foreground 300 sleep 20)')
check "timeout --foreground: Ctrl-C stops it ($out)" '[[ "$out" == exited* ]]'
check "no plain 'timeout N' left in the CLI" '! grep -nE "(^|[^-])timeout +[0-9\"\$]" "$REPO/bin/isardvdi" | grep -v -- --foreground | grep -q .'

echo "== 4 nested C1"
check "c2 c2 9b 9b -> nothing left" '[[ "$(sanitize $'"'"'a\xc2\xc2\x9b\x9bb'"'"')" == ab ]]'
check "c2 01 9b (C0 inside) -> nothing left" '[[ "$(sanitize $'"'"'a\xc2\x01\x9bb'"'"')" == ab ]]'
check "normal accents kept" '[[ "$(sanitize "Vergés García")" == "Vergés García" ]]'

echo "== 5 a failed write never loses the secret"
f="$CONF_DIR/selftest"
if keyring_ok; then
    printf 'v1' | secret_save selftest "$f"
    ( write_secret() { die "disk full (simulated)"; }; printf 'v2' | ISARDVDI_KEYRING=0 secret_save selftest "$f" ) 2>/dev/null
    check "file write fails -> keyring copy and marker kept" '[[ -f "$f.in-keyring" && "$(secret_load selftest "$f")" == v1 ]]'
    secret_clear selftest "$f"
else
    skip "keyring copy kept (no keyring running)"
fi
printf 'v1' | write_secret "$f"
( eval "real_$(declare -f write_secret)"
  write_secret() { [[ "$1" == *.in-keyring ]] && die "disk full (simulated)"; real_write_secret "$@"; }
  printf 'v1' | secret_save selftest "$f" ) 2>/dev/null
check "marker write fails -> the key file stays" '[[ -f "$f" && $(cat "$f") == v1 ]]'
secret_clear selftest "$f"; rm -f "$f"

finish
