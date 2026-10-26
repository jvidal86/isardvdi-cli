#!/usr/bin/env bash
# API key storage (keyring or file) and automatic renewal from the browser, with fake keys.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

echo "== keyring (item 'selftest')"
f="$CONF_DIR/selftest"
if keyring_ok; then
    printf 'secret-1' | secret_save selftest "$f"
    check "stored in the keyring"         '[[ -f "$f.in-keyring" && ! -f "$f" ]]'
    check "loaded back"                   '[[ "$(secret_load selftest "$f")" == secret-1 ]]'
    secret_clear selftest "$f"
    secret_load selftest "$f" >/dev/null; rc=$?
    check "cleared"                       '[[ $rc == 1 ]] && ! secret-tool lookup service isardvdi-cli item selftest >/dev/null 2>&1'
    : > "$f.in-keyring"
    secret_load selftest "$f" >/dev/null; rc=$?
    check "marker without keyring item -> rc 2" '[[ $rc == 2 ]]'
    rm -f "$f.in-keyring"
else
    skip "keyring tests (no keyring running)"
fi
printf 'secret-2' | ISARDVDI_KEYRING=0 secret_save selftest "$f"
check "no keyring -> private file"        '[[ -f "$f" && ! -f "$f.in-keyring" && $(stat -c %a "$f") == 600 ]]'
rm -f "$f"

echo "== renewal (file storage, sign-in stubbed)"
uid=11111111-2222-3333-4444-555555555555
tok "{\"type\":\"external\",\"session_id\":\"api-key\",\"exp\":$((now+10*86400)),\"data\":{\"user_id\":\"$uid\"}}" \
    > "$APIKEY_FILE"
key_before=$(cat "$APIKEY_FILE")

# 1. No browser token: renewal fails quietly, the warning shows, the attempt is stamped.
out=$(cli list 2>&1)
check "warning shown when renewal fails"  'grep -q "renews itself while the portal" <<<"$out"'
check "renew stamp written"               '[[ -f "$RENEW_STAMP" ]]'
check "key unchanged"                     '[[ "$(cat "$APIKEY_FILE")" == "$key_before" ]]'

# 2. A browser token for ANOTHER user must not be used, even if offered.
rm -f "$RENEW_STAMP"
other=$(tok "{\"type\":\"login\",\"session_id\":\"s1\",\"exp\":$((now+600)),\"data\":{\"user_id\":\"someone-else\",\"name\":\"X\"}}")
printf 'print("%s")\n' "$other" > "$T/helpers/browser_token.py"
rm -f "$T/curl.log"
out=$(cli list 2>&1)
check "other user's token not used"       '! grep -q "Renewed" <<<"$out" && [[ "$(cat "$APIKEY_FILE")" == "$key_before" ]]'
check "... not even sent to the server"   '! grep -q "api-key\|$other" "$T/curl.log"'

# 3. A matching token the server doesn't accept (here: no answer): no renewal, no crash.
rm -f "$RENEW_STAMP" "$T/curl.log"
mine=$(tok "{\"type\":\"login\",\"session_id\":\"s1\",\"exp\":$((now+600)),\"data\":{\"user_id\":\"$uid\",\"name\":\"Me\"}}")
printf 'print("%s")\n' "$mine" > "$T/helpers/browser_token.py"
out=$(cli list 2>&1)
check "failed renewal keeps the key"      '! grep -q "Renewed" <<<"$out" && [[ "$(cat "$APIKEY_FILE")" == "$key_before" ]]'
check "... after asking with the browser token" 'grep -q "/authentication/api-key" "$T/curl.log" && grep -q "Bearer $mine" "$T/curl.log"'

# 3b. The server answers with a new key: stored, and announced.
rm -f "$RENEW_STAMP"
new=$(tok "{\"type\":\"external\",\"session_id\":\"api-key\",\"exp\":$((now+90*86400)),\"data\":{\"user_id\":\"$uid\"}}")
printf '%s' "$new" > "$T/new-key"
out=$(cli list 2>&1)
check "renewed: new key stored"           'grep -q "Renewed the API key" <<<"$out" && [[ "$(cat "$APIKEY_FILE")" == "$new" ]]'
# 3c. The server answers with something that isn't an API key: nothing stored.
rm -f "$RENEW_STAMP"
tok "{\"type\":\"login\",\"session_id\":\"s1\",\"exp\":$((now+90*86400))}" > "$T/new-key"
printf '%s' "$key_before" > "$APIKEY_FILE"
out=$(cli list 2>&1)
check "not an API key: not stored"        '! grep -q "Renewed" <<<"$out" && [[ "$(cat "$APIKEY_FILE")" == "$key_before" ]]'
rm -f "$T/new-key"

# 4. Throttle: a second run within the hour doesn't call the browser helper.
printf 'open("%s/BROWSER_CALLED", "w"); raise SystemExit(1)\n' "$T" > "$T/helpers/browser_token.py"
cli list >/dev/null 2>&1
check "throttled to once an hour"         '[[ ! -e "$T/BROWSER_CALLED" ]]'

# 5. Not yet in the renewal window: no attempt at all.
rm -f "$RENEW_STAMP"
tok "{\"type\":\"external\",\"session_id\":\"api-key\",\"exp\":$((now+60*86400)),\"data\":{\"user_id\":\"$uid\"}}" \
    > "$APIKEY_FILE"
out=$(cli list 2>&1)
check "no attempt outside the window"     '[[ ! -e "$T/BROWSER_CALLED" ]] && ! grep -q "Note:" <<<"$out"'

# 6. create --from-browser with no browser session and no terminal: refuses cleanly.
cli apikey create --from-browser </dev/null >/dev/null 2>&1; rc=$?
check "create without session/terminal refuses" '[[ $rc -ne 0 ]]'

check "SAML sign-in never called"         '[[ ! -e "$T/SSO_CALLED" ]]'
finish
