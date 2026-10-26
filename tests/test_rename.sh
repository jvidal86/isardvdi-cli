#!/usr/bin/env bash
# Tests for 'rename', server mocked: every API call is logged to $T/calls.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
U1=11111111-1111-1111-1111-111111111111
find_desktop() { echo "$U1"; }
api_call() { echo "$1 $2 ${3:-}" >> "$T/calls"; echo '{}'; }
# The desktop's state lives in $T/state; a stop request turns it to Stopped, a start to Started.
desktop_from_list() {
    [[ -s "$T/calls" ]] && grep -q "/stop" "$T/calls" && ! grep -q "/start" "$T/calls" && echo Stopped > "$T/state"
    [[ -s "$T/calls" ]] && grep -q "/start" "$T/calls" && echo Started > "$T/state"
    local ip=null; [[ $(cat "$T/state") == Started ]] && ip='"10.2.0.9"'
    echo "{\"id\":\"$U1\",\"status\":\"$(cat "$T/state")\",\"ip\":$ip}"
}
sleep() { :; }
run() { rm -f "$T/calls"; echo "$1" > "$T/state"; shift; ( cmd_rename "$@" ) >"$T/out" 2>&1; rc=$?; }
calls() { cut -d' ' -f1,2 "$T/calls" 2>/dev/null | sed "s|/api/v4/item/desktop/$U1||" | tr '\n' ' '; }

echo "== 1 names"
for n in "Ubuntu/athena" "abc" "$(printf 'a%.0s' {1..51})" "x;id" $'two\nlines'; do
    run Stopped zeus "$n"
    check "refuses '$(printf %q "$n")', no API call" '[[ $rc != 0 && ! -e "$T/calls" ]]'
done
run Stopped zeus "Ubuntu 24 server - athena"
check "accepts accents-free name with ' - '" '[[ $rc == 0 ]]'
run Stopped zeus "Màquina d'en Joan" 2>/dev/null
check "refuses an apostrophe" '[[ $rc != 0 ]]'
run Stopped zeus "Màquina àèìòù"
check "accepts accented letters" '[[ $rc == 0 ]]'

echo "== 2 stopped desktop"
run Stopped zeus "athena box"
check "renamed with only the name" '[[ "$(calls)" == "PUT /edit " ]] && grep -q "{\"name\":\"athena box\"}" "$T/calls"'
check "stays stopped (no start)" '! grep -q /start "$T/calls"'
run Failed zeus "athena box"
check "a failed desktop is renamed too" '[[ "$(calls)" == "PUT /edit " ]]'
run Stopped zeus "athena box" --restart
check "--restart on a stopped one doesn't start it" '[[ "$(calls)" == "PUT /edit " ]]'

echo "== 3 running desktop"
run Started zeus "athena box"
check "refused without --restart" '[[ $rc != 0 && ! -e "$T/calls" ]] && grep -q -- "--restart" "$T/out"'
run Started zeus "athena box" --restart
check "--restart: stop, edit, start in that order" '[[ $rc == 0 && "$(calls)" == "PUT /stop PUT /edit PUT /start " ]]'
check "--restart: reports the new IP" 'grep -q "Started again: ip=10.2.0.9" "$T/out"'

echo "== 4 never renames a desktop that didn't stop"
desktop_from_list() { echo "{\"id\":\"$U1\",\"status\":\"Stopping\",\"ip\":null}"; }
START_TIMEOUT=0 run Started zeus "athena box" --restart
check "timeout: stop sent, edit never sent" '[[ $rc != 0 && "$(calls)" == "PUT /stop " ]]'

echo "== 5 usage"
run Stopped zeus
check "missing new name -> usage" '[[ $rc != 0 ]] && grep -q "Usage: isardvdi rename" "$T/out"'
run Stopped zeus "athena box" --force
check "unknown flag refused" '[[ $rc != 0 && ! -e "$T/calls" ]]'
check "dispatched from the command line" 'grep -q "^    rename)  *cmd_rename" "$REPO/bin/isardvdi"'

finish
