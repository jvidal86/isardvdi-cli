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
check "... and, the browser's token being old, that a fresh sign-in may not be saved yet" 'grep -q "may not have saved it yet" "$T/out"'
TOKEN=$NEW
run web_keepalive
check "a still-valid token refused: no such hint" '[[ $rc == 4 ]] && ! grep -q "may not have saved" "$T/out"'
TOKEN=$(tok "{\"type\":\"login\",\"session_id\":\"s1\",\"exp\":$((now - 600)),\"data\":{\"user_id\":\"u1\"}}")
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

echo "== 4 sharing the session: checks"
OTHER=$(tok "{\"type\":\"login\",\"session_id\":\"s2\",\"exp\":$((now + 3600)),\"data\":{\"user_id\":\"someone-else\"}}")
KEY=$(tok "{\"type\":\"login\",\"session_id\":\"api-key\",\"exp\":$((now + 3600)),\"data\":{\"user_id\":\"u1\"}}")
run check_shared_token "$NEW"
check "your fresh session: accepted" '[[ $rc == 0 ]]'
run check_shared_token "$OTHER"
check "another account's session: refused" '[[ $rc != 0 ]] && grep -q "another IsardVDI account" "$T/out"'
run check_shared_token "$KEY"
check "an API key: refused" '[[ $rc != 0 ]]'
run check_shared_token "$TOKEN"
check "an expired token: refused" '[[ $rc != 0 ]]'
for bad in "-oProxyCommand=x" "a b" "x;id" 'h$(id)' "@host" "user@"; do
    run web_peer "$bad"
    check "SSH destination '$bad' refused" '[[ $rc != 0 ]]'
done
printf 'URL=https://portal.example\nSSH_USER=isard\n' > "$CONF_FILE"
WEB_PEER=""
( web_peer jvidal@pc.example ) >/dev/null 2>&1
check "a new destination is remembered, the rest of the config kept" \
    'grep -qx "WEB_PEER=jvidal@pc.example" "$CONF_FILE" && grep -qx "SSH_USER=isard" "$CONF_FILE" && [[ $(stat -c %a "$CONF_FILE") == 600 ]]'

echo "== 5 web pull (from the other computer over SSH)"
CLIP=""
web_clipboard() { printf '%s' "$1" > "$T/clip"; }
ssh() { printf '%s\n' "$@" > "$T/ssh-args"; cat > "$T/ssh-stdin"; [[ -n "${SSH_OUT:-}" ]] && printf '%s\n' "$SSH_OUT"; return "${SSH_RC:-0}"; }
WEB_PEER=jvidal@pc.example SSH_OUT=$NEW SSH_RC=0
rm -f "$T/clip"
run web_pull
check "pulled: on the clipboard, says which button to press" '[[ $rc == 0 ]] && [[ "$(cat "$T/clip")" == "$NEW" ]] && grep -q "Use the shared session" "$T/out"'
check "runs 'web token' there, after --, without agent or X11 forwarding" \
    'grep -qx -- "--" "$T/ssh-args" && grep -qx "jvidal@pc.example" "$T/ssh-args" && grep -q "exec \"\$p\" web token$" "$T/ssh-args" && grep -qx "ForwardAgent=no" "$T/ssh-args"'
check "the session is never printed" '! grep -qF "$NEW" "$T/out"'
SSH_OUT=$OTHER
rm -f "$T/clip"
run web_pull
check "the other computer hands another account's session: refused, clipboard untouched" '[[ $rc != 0 && ! -e "$T/clip" ]]'
SSH_OUT="" SSH_RC=4
run web_pull
check "the other computer's session has ended: fails, says so" '[[ $rc != 0 ]] && grep -q "exit 4" "$T/out"'
SSH_OUT=$NEW SSH_RC=0
( web_pull --print ) > "$T/printed" 2>/dev/null; rc=$?
check "--print into a pipe: just the session" '[[ $rc == 0 && "$(cat "$T/printed")" == "$NEW" ]]'
check "--print refuses a terminal" 'grep -q "only into a pipe, never to the screen" "$REPO/bin/isardvdi"'

echo "== 6 web push / receive (the other way)"
SSH_RC=0 SSH_OUT=""
browser_portal_token() { printf '%s' "$TOKEN"; }
CODE=200 ANSWER="{\"token\":\"$NEW\"}"
run web_push
check "push: renews, then sends the fresh session on SSH's stdin" \
    '[[ $rc == 0 ]] && [[ "$(cat "$T/ssh-stdin")" == "$NEW" ]] && grep -q "exec \"\$p\" web receive$" "$T/ssh-args"'
check "... never on its command line" '! grep -qF "$NEW" "$T/ssh-args" && ! grep -qF "$TOKEN" "$T/ssh-args"'
WEB_PEER=""
run web_push
check "push with nowhere to send: asks for --to" '[[ $rc != 0 ]] && grep -q -- "--to" "$T/out"'
rm -f "$WEB_SESSION_FILE"
( web_receive <<< "$OTHER" ) >/dev/null 2>&1; rc=$?
check "receive: another account's session refused, nothing stored" '[[ $rc != 0 && ! -e "$WEB_SESSION_FILE" ]]'
( web_receive <<< "$NEW" ) >"$T/out" 2>&1; rc=$?
check "receive: stored, private" '[[ $rc == 0 && $(stat -c %a "$WEB_SESSION_FILE") == 600 ]] && [[ "$(cat "$WEB_SESSION_FILE")" == "$NEW" ]]'
NEWER=$(tok "{\"type\":\"login\",\"session_id\":\"s1\",\"exp\":$((now + 3500)),\"data\":{\"user_id\":\"u1\"}}")
CODE=200 ANSWER="{\"token\":\"$NEWER\"}"
rm -f "$T/clip"
run web_pull
check "pull here, no peer: the received session, renewed first" \
    '[[ $rc == 0 ]] && [[ "$(cat "$T/clip")" == "$NEWER" ]] && [[ "$(cat "$WEB_SESSION_FILE")" == "$NEWER" ]]'
CODE=401 ANSWER='{}'
run web_pull
check "received session has ended: fails, file removed" '[[ $rc == 4 && ! -e "$WEB_SESSION_FILE" ]]'
run web_pull
check "nothing received and no peer: says how to start" '[[ $rc != 0 ]] && grep -q -- "--from" "$T/out"'

echo "== 7 the browser extension"
URL=https://portal.example
rm -rf "$T/ext"
( web_extension "$T/ext" ) > "$T/out" 2>&1; rc=$?
check "writes manifest, popup page and script" '[[ $rc == 0 && -f "$T/ext/manifest.json" && -f "$T/ext/popup.html" && -f "$T/ext/popup.js" ]]'
check "only this portal, only cookies/clipboard/tabs" \
    '[[ $(jq -c .host_permissions "$T/ext/manifest.json") == "[\"https://portal.example/*\"]" ]] && [[ $(jq -c .permissions "$T/ext/manifest.json") == "[\"cookies\",\"clipboardRead\",\"clipboardWrite\",\"tabs\"]" ]]'
check "sets isardvdi_session Secure, SameSite strict, on the portal" \
    'grep -q "const PORTAL = .https://portal.example.;" "$T/ext/popup.js" && grep -qF "name: '"'"'isardvdi_session'"'"', value: t, path: '"'"'/'"'"', secure: true, sameSite: '"'"'strict'"'"'" "$T/ext/popup.js"'
check "refuses API keys and expired tokens, empties the clipboard after use" \
    'grep -qF "c.session_id !== '"'"'api-key'"'"'" "$T/ext/popup.js" && grep -qF "c.exp * 1000 > Date.now()" "$T/ext/popup.js" && grep -qF "navigator.clipboard.writeText('"'"''"'"')" "$T/ext/popup.js"'
check "no remote code: one local script, no network calls" '! grep -qE "fetch\(|XMLHttpRequest|<script src=.http" "$T/ext/popup.js" "$T/ext/popup.html"'
if command -v node >/dev/null 2>&1; then
    check "popup.js is valid JavaScript" 'node --check "$T/ext/popup.js"'
else skip "node (JavaScript syntax)"; fi
ln -s "$T/ext" "$T/ext-link"
( web_extension "$T/ext-link" ) >/dev/null 2>&1; rc=$?
check "refuses to write through a symlink" '[[ $rc != 0 ]]'
check "forget deletes a received session" 'grep -q "rm -f \"\$VPN_FILE\" \"\$RENEW_STAMP\" \"\$WEB_SESSION_FILE\"" "$REPO/bin/isardvdi"'

echo "== 8 secret clipboard helper"
check "marks the text for clipboard histories, clears it after the time" \
    'grep -q "x-kde-passwordManagerHint" "$REPO/lib/secret_clipboard.py" && grep -q "cb.clear()" "$REPO/lib/secret_clipboard.py"'
check "empty input: refuses" '! printf "\n" | python3 -I "$REPO/lib/secret_clipboard.py"'
check "installed by install.sh" 'grep -q "secret_clipboard.py" "$REPO/install.sh"'

echo "== 9 web link (set up the other computer)"
REAL_HOME=$HOME
HOME=$T/home; mkdir -p "$HOME/.ssh"
printf 'Host work\n    HostName work.example\n' > "$HOME/.ssh/config"
mkdir -p "$T/cfbin"; printf '#!/bin/sh\n' > "$T/cfbin/cloudflared"; chmod 755 "$T/cfbin/cloudflared"
ssh() { printf '%s\n' "$@" > "$T/ssh-args"; return 0; }
WEB_PEER=""
( PATH="$T/cfbin:$PATH"; web_link jvidal@ssh.example.com --cloudflare ) > "$T/out" 2>&1; rc=$?
check "writes the entry, keeps your other hosts" \
    '[[ $rc == 0 ]] && grep -qx "Host isardvdi-peer" "$HOME/.ssh/config" && grep -qx "    HostName ssh.example.com" "$HOME/.ssh/config" && grep -qx "    User jvidal" "$HOME/.ssh/config" && grep -qx "Host work" "$HOME/.ssh/config"'
check "through cloudflared, quoted path" 'grep -qx "    ProxyCommand \"$T/cfbin/cloudflared\" access ssh --hostname %h" "$HOME/.ssh/config"'
check "private, remembered, tested" '[[ $(stat -c %a "$HOME/.ssh/config") == 600 ]] && grep -qx "WEB_PEER=isardvdi-peer" "$CONF_FILE" && grep -qx "isardvdi-peer" "$T/ssh-args" && grep -q Connected "$T/out"'
( PATH="$T/cfbin:$PATH"; web_link other.example.com ) >/dev/null 2>&1
check "run again: replaced, not added twice" '[[ $(grep -c "^Host isardvdi-peer" "$HOME/.ssh/config") == 1 ]] && grep -qx "    HostName other.example.com" "$HOME/.ssh/config" && ! grep -q ProxyCommand "$HOME/.ssh/config" && grep -qx "Host work" "$HOME/.ssh/config"'
for bad in "-oProxyCommand=x" "a b" $'h\nProxyCommand x' "u@" "x;id"; do
    ( web_link "$bad" ) >/dev/null 2>&1; rc=$?
    check "destination '$(printf %q "$bad")' refused" '[[ $rc != 0 ]]'
done
mkdir -p "$T/empty"
# shellcheck disable=SC2123  # no PATH on purpose: no cloudflared to find
( PATH="$T/empty"; web_link h.example --cloudflare ) > "$T/out" 2>&1; rc=$?
check "--cloudflare without cloudflared: says how to install" '[[ $rc != 0 ]] && grep -q "cloudflared isn.t installed" "$T/out"'
ssh() { return 255; }
( web_link h.example ) > "$T/out" 2>&1; rc=$?
check "connection fails: says so" '[[ $rc != 0 ]] && grep -q "connection failed" "$T/out"'
HOME=$REAL_HOME

finish
