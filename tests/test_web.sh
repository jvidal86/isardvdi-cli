#!/usr/bin/env bash
# Tests for 'web keepalive'. The browser and the server are mocked: no cookie is read, nothing
# is sent anywhere. curl's arguments are logged to $T/curl-args, its auth header to $T/curl-hdr.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
URL=https://portal.example
load_config() { :; }
apikey_user_id() { echo u1; }
TOKEN=$(tok "{\"type\":\"login\",\"session_id\":\"s1\",\"exp\":$((now - 600)),\"data\":{\"user_id\":\"u1\"}}")
NEW=$(tok "{\"type\":\"login\",\"session_id\":\"s1\",\"exp\":$((now + 3600)),\"data\":{\"user_id\":\"u1\"}}")
browser_portal_token() { printf '%s\n' "$*" > "$T/bpt-args"; printf '%s' "$TOKEN"; }
ANSWER="{\"token\":\"$NEW\"}" CODE=200
curl() {
    printf '%s\n' "$@" > "$T/curl-args"
    local a; for a in "$@"; do [[ "$a" == @/dev/fd/* || "$a" == @/proc/self/fd/* ]] && cat "${a#@}" > "$T/curl-hdr"; done
    [[ "$CODE" == fail ]] && return 7
    printf '%s\n%s' "$ANSWER" "$CODE"
}
run() { rm -f "$T/curl-args" "$T/curl-hdr"; ( set -e; "$@" ) >"$T/out" 2>&1; rc=$?; }

echo "== 1 renew"
run web_keepalive
check "renewed: exit 0, says until when" '[[ $rc == 0 ]] && grep -q "Web session renewed: valid until" "$T/out"'
check "asks the browser for this account's token, expired ones too" 'grep -q "^u1 60 --allow-expired$" "$T/bpt-args"'
check "POST to the portal's /authentication/renew, https only" \
    'grep -qx "$URL/authentication/renew" "$T/curl-args" && grep -qx POST "$T/curl-args" && grep -qx "=https" "$T/curl-args"'
check "the token never on curl's command line" '! grep -qF "$TOKEN" "$T/curl-args"'
check "... but in its Authorization header, from a file descriptor" 'grep -qxF "Authorization: Bearer $TOKEN" "$T/curl-hdr"'
check "the new token is never printed" '! grep -qF "$NEW" "$T/out"'

echo "== 2 failures"
browser_portal_token() { return 1; }
run web_keepalive
check "no session in the browser: exit 3, nothing sent" '[[ $rc == 3 && ! -e "$T/curl-args" ]] && grep -q "sign in" "$T/out"'
browser_portal_token() { printf '%s' "$TOKEN"; }
CODE=401 ANSWER='{"error":"invalid_session"}'
run web_keepalive
check "session ended (401): exit 4, says sign in again" '[[ $rc == 4 ]] && grep -q "sign in" "$T/out"'
CODE=fail
run web_keepalive
check "no answer: exit 75" '[[ $rc == 75 ]]'
CODE=502 ANSWER='<html>bad gateway</html>'
run web_keepalive
check "server error: exit 75" '[[ $rc == 75 ]]'
CODE=200 ANSWER='{"token":"not-a-jwt"}'
run web_keepalive
check "renewed, odd answer: still exit 0" '[[ $rc == 0 ]] && grep -q "Web session renewed" "$T/out"'
run web_keepalive extra
check "extra argument: usage" '[[ $rc != 0 ]] && grep -q "Usage: isardvdi web keepalive" "$T/out"'

echo "== 3 browser helper: expired tokens only when asked"
check "usable(): expired refused by default, accepted with expired_ok" \
    'python3 -I -c "import sys,time,json,base64; sys.path.insert(0, \"$REPO/lib\"); import browser_token as b
p=lambda d: \"x.\"+base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip(\"=\")+\".y\"
t=p({\"type\":\"login\",\"session_id\":\"s\",\"exp\":time.time()-600,\"data\":{\"user_id\":\"u\"}})
old=p({\"type\":\"login\",\"session_id\":\"s\",\"exp\":time.time()-2*86400,\"data\":{\"user_id\":\"u\"}})
k=p({\"type\":\"login\",\"session_id\":\"api-key\",\"exp\":time.time()+600,\"data\":{\"user_id\":\"u\"}})
assert not b.usable(t, \"u\") and b.usable(t, \"u\", True)
assert not b.usable(old, \"u\", True) and not b.usable(k, \"u\", True)"'
check "dispatched" 'grep -q "^    web)  *cmd_web" "$REPO/bin/isardvdi"'

finish
