#!/usr/bin/env bash
# Regression tests for the media, template, viewer and get commands' audit, server mocked.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
U1=11111111-1111-1111-1111-111111111111 U2=22222222-2222-2222-2222-222222222222

echo "== 1 the API path can't change the host"
for p in ".evil.example/x" "@evil.example/x" "x" "/api/ok"$'\n'"Host: x" ""; do
    rm -f "$T/curl"
    ( curl() { touch "$T/curl"; printf 'x\n200'; }; get_jwt() { echo t; }
      api_call GET "$p" ) >/dev/null 2>&1; rc=$?
    check "path '$(printf %q "$p")' refused, token not sent" '[[ $rc != 0 && ! -e "$T/curl" ]]'
done
( curl() { touch "$T/curl"; printf '{}\n200'; }; get_jwt() { echo t; }
  api_call GET "/api/v4/items/desktops" ) >/dev/null 2>&1
check "a normal path still works" '[[ -e "$T/curl" ]]'

echo "== 2 wait_media"
sleep() { :; }
media_json() { echo x >> "$T/n"; return 1; }
( wait_media $U1 60 ) >/dev/null 2>&1; rc=$?
check "a hard error (401, failed sign-in) stops at once" '[[ $rc != 0 && $(wc -l < "$T/n") == 1 ]]'
rm -f "$T/n"
media_json() { echo x >> "$T/n"; [[ $(wc -l < "$T/n") -le 2 ]] && return 75; echo "[{\"id\":\"$U1\",\"status\":\"Downloaded\"}]"; }
( wait_media $U1 60 ) >/dev/null 2>&1; rc=$?
check "temporary errors retried, then Downloaded" '[[ $rc == 0 ]]'
media_json() { echo "[{\"id\":\"$U1\",\"status\":\"Down\u001b]52;c;QQ==\u0007loading\",\"progress\":{\"received_percent\":\"\u001b[2J\"}}]"; }
out=$( ( wait_media $U1 1 ) 2>&1 )
check "state and percent printed clean" '[[ "$out" != *$'"'"'\e'"'"'* && "$out" != *$'"'"'\a'"'"'* ]]'
unset -f sleep
media_json() { command sleep 2; return 75; }
start=$SECONDS; ( wait_media $U1 4 ) >/dev/null 2>&1
check "deadline in real seconds (took $((SECONDS-start)) s)" '[[ $((SECONDS-start)) -le 8 ]]'
unset -f media_json
source <(sed -n '/^media_json()/,/^}/p' "$REPO/bin/isardvdi")

echo "== 3 your own media win"
api_get() { case "$1" in
    */get-shared) echo "{\"media\":[{\"id\":\"$U2\",\"name\":\"ubuntu-24.iso\"}]}" ;;
    *) echo "{\"media\":[{\"id\":\"$U2-x\",\"name\":null},{\"id\":\"$U1\",\"name\":\"ubuntu-24.iso\"}]}" ;; esac; }
check "own media chosen despite a null name" '[[ "$(find_media ubuntu-24 2>/dev/null)" == $U1 ]]'

echo "== 4 shared media optional"
api_get() { case "$1" in */get-shared) return 1 ;; *) echo "{\"media\":[{\"id\":\"$U1\",\"name\":\"mine\"}]}" ;; esac; }
check "get-shared failing -> own media still listed" '[[ $(media_json 2>/dev/null | jq -r ".[0].id") == $U1 ]]'
api_get() { case "$1" in */get-shared) echo "<html>" ;; *) echo "{\"media\":[]}" ;; esac; }
check "get-shared not JSON -> empty list, no crash" '[[ $(media_json 2>/dev/null) == "[]" ]]'
api_get() { return 1; }
check "own media failing -> error (not an empty list)" '! media_json >/dev/null 2>&1'
unset -f api_get

echo "== 5 groups: exact name or id only"
api_call() { echo '[{"id":"g-1","name":"ASIX2 Mati"},{"id":"g-2","name":"ASIX1 Tarda"}]'; }
check "prefix 'ASIX' refused"           '! ( find_group ASIX ) >/dev/null 2>&1'
check "exact name -> its id"            '[[ $(find_group "asix2 mati" 2>/dev/null) == g-1 ]]'
check "exact id -> itself"              '[[ $(find_group g-2 2>/dev/null) == g-2 ]]'
check "says which group"                'find_group "ASIX2 Mati" 2>&1 >/dev/null | grep -q "Sharing with group: ASIX2 Mati (g-1)"'
api_call() { echo '[{"id":"../x","name":"Evil"}]'; }
check "unsafe group id refused"         '! ( find_group Evil ) >/dev/null 2>&1'
unset -f api_call

echo "== 6 minor"
check "viewer file goes through harden_vv" 'grep -q "harden_vv 0 | write_secret \"\$out\"" "$REPO/bin/isardvdi"'
check "hardware numbers validated"         'grep -q -- "--memory, --vcpus and --disk take whole numbers" "$REPO/bin/isardvdi"'
check "template group lookup stops on failure" 'grep -q "g=\$(find_group \"\$g\") || exit 1" "$REPO/bin/isardvdi"'

finish
