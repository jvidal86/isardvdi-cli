#!/usr/bin/env bash
# Which desktop a single id or name means (resolve_target), server mocked. In particular a
# bastion SSH id (the user in "ssh <id>@bastion...") is taken as its desktop, instead of the
# server's misleading 403 not_enough_rights_desktop.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
D1=11111111-1111-1111-1111-111111111111   # your desktop "athena"
B1=22222222-2222-2222-2222-222222222222   # its bastion SSH id
S1=33333333-3333-3333-3333-333333333333   # a student's desktop (not in your list)
list_desktops_json() { echo "[{\"id\":\"$D1\",\"name\":\"athena\"}]"; }
bastions='[{"id":"'$B1'","desktop_id":"'$D1'","ssh":{"enabled":true}}]'
api_get() { echo "$1" >> "$T/calls"; [[ "$1" == /api/v4/items/bastions ]] && printf '%s' "$bastions"; }
run() { rm -f "$T/calls"; resolve_target "$@" 2>"$T/err"; rc=$?; }

echo "== 1 your desktop"
run "$D1"
check "by id: own, no extra call"         '[[ $rc == 0 && $TARGET_ID == "$D1" && $TARGET_OWN == 1 && ! -e "$T/calls" ]]'
run athena
check "by name: own"                      '[[ $rc == 0 && $TARGET_ID == "$D1" && $TARGET_OWN == 1 ]]'

echo "== 2 a bastion SSH id"
run "$B1"
check "becomes its desktop, owned"        '[[ $rc == 0 && $TARGET_ID == "$D1" && $TARGET_OWN == 1 ]]'
check "says so, naming the desktop"       'grep -q "bastion SSH id of desktop \"athena\"" "$T/err"'

echo "== 3 any other id is left alone"
run "$S1"
check "unchanged, not owned"              '[[ $rc == 0 && $TARGET_ID == "$S1" && $TARGET_OWN == 0 ]] && [[ ! -s "$T/err" ]]'
bastions='{"error":"forbidden"}'
run "$S1"
check "odd bastions answer: unchanged"    '[[ $rc == 0 && $TARGET_ID == "$S1" ]]'
bastions='[{"id":"'$S1'","desktop_id":"not-a-uuid; rm -rf ~"}]'
run "$S1"
check "invalid desktop id from server: ignored" '[[ $rc == 0 && $TARGET_ID == "$S1" ]]'

finish
