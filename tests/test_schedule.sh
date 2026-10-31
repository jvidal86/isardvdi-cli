#!/usr/bin/env bash
# Tests for 'schedule'. systemd and the server are mocked: units are written under the throwaway
# config dir, systemctl calls go to $T/sysctl and API calls to $T/calls.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
D1=d1111111-1111-1111-1111-111111111111 D2=d2222222-2222-2222-2222-222222222222
S1=51111111-1111-1111-1111-111111111111 S2=52222222-2222-2222-2222-222222222222
U="$SYSTEMD_USER_DIR"

list_deployments_json() {
    echo "[{\"id\":\"$D1\",\"name\":\"win server 25 Unique SID\",\"total_desktops\":10},
           {\"id\":\"$D2\",\"name\":\"Windows 11 uniquie SID ASIX2\",\"total_desktops\":10}]"
}
systemctl() { :; }   # "installed" (the real calls go through sched_systemctl, mocked below)
sched_systemctl() {
    echo "$*" >> "$T/sysctl"
    [[ "$1" == show ]] && echo "Tue 2026-11-03 14:58:00 CET"
    return 0
}
STATE=Stopped
deployment_desktops_json() {
    [[ "$1" == "$D1" ]] && echo "[{\"id\":\"$S1\",\"user_name\":\"Pol A\",\"group_name\":\"26-27_ASIX2\",\"status\":\"$STATE\"},
                                {\"id\":\"$S2\",\"user_name\":\"Teacher\",\"group_name\":\"docents\",\"status\":\"$STATE\"}]" || echo '[]'
}
api_call() { echo "$1 $2 ${3:-}" >> "$T/calls"; echo '{}'; }
using_apikey() { return 0; }
sleep() { :; }
# Notifications are recorded, never shown on the desktop running the tests.
sched_notify() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$T/notify"; }
run() { rm -f "$T/calls" "$T/sysctl"; ( set -e; "$@" ) >"$T/out" 2>&1; rc=$?; }

echo "== 1 times"
check "day names, English and Catalan" '[[ "$(day_norm TUE) $(day_norm dj) $(day_norm divendres)" == "Tue Thu Fri" ]]'
check "a slot with two days" '[[ "$(parse_slot "tue,dj 9:05" | tr "\n" ,)" == "Tue 09:05,Thu 09:05," ]]'
for bad in "tue" "tue 25:00" "tue 15:60" "xyz 15:00" "tue 15:00 extra" "15:00 tue"; do
    ( parse_slot "$bad" ) >/dev/null 2>&1; rc=$?
    check "refuses --at '$bad'" '[[ $rc != 0 ]]'
done
check "2 min before Tue 15:00" '[[ "$(slot_minus "Tue 15:00" 2)" == "Tue 14:58" ]]'
check "crossing midnight goes back a day" '[[ "$(slot_minus "Mon 00:01" 2)" == "Sun 23:59" ]]'
check "0 minutes before" '[[ "$(slot_minus "Fri 18:30" 0)" == "Fri 18:30" ]]'

echo "== 2 add"
run cmd_schedule add aso --at "tue 15:00" --at "thu 16:00" --deployment "win server" --deployment "Windows 11" --group asix2
check "added" '[[ $rc == 0 ]] && jq -e ".[0].name == \"aso\" and .[0].before == 2 and (.[0].deployments | length) == 2 and .[0].groups == [\"asix2\"]" "$SCHED_FILE" >/dev/null'
check "the file is private" '[[ $(stat -c %a "$SCHED_FILE") == 600 ]]'
check "timer fires 2 min before each class" 'grep -qx "OnCalendar=Tue \*-\*-\* 14:58:00" "$U/isardvdi-schedule-aso.timer" && grep -qx "OnCalendar=Thu \*-\*-\* 15:58:00" "$U/isardvdi-schedule-aso.timer"'
check "no catch-up run after the computer was off" '! grep -q Persistent "$U/isardvdi-schedule-aso.timer"'
check "service runs 'schedule run aso --from-timer'" 'grep -q "^ExecStart=/.* schedule run aso --from-timer$" "$U/isardvdi-schedule-aso.service"'
check "timer enabled and started" 'grep -q "enable isardvdi-schedule-aso.timer" "$T/sysctl" && grep -q "restart isardvdi-schedule-aso.timer" "$T/sysctl"'
check "list shows class, deployments and next run" 'grep -q "Tue 15:00, Thu 16:00" "$T/out" && grep -q "Windows 11 uniquie SID ASIX2  (10 desktops)" "$T/out" && grep -q "next:    Tue 2026-11-03 14:58" "$T/out"'
run cmd_schedule add aso --at "mon 15:00" --deployment "win server"
check "duplicate name refused" '[[ $rc != 0 ]] && [[ $(jq length "$SCHED_FILE") == 1 ]]'
run cmd_schedule add "Bad Name" --at "mon 15:00" --deployment "win server"
check "bad name refused" '[[ $rc != 0 ]]'
run cmd_schedule add bd --at "mon 15:00"
check "no deployment refused" '[[ $rc != 0 ]] && [[ $(jq length "$SCHED_FILE") == 1 ]]'
run cmd_schedule add bd --deployment "win server"
check "no --at refused" '[[ $rc != 0 ]]'
run cmd_schedule add bd --at "mon 15:00" --deployment "nothing like it"
check "unknown deployment refused" '[[ $rc != 0 ]] && [[ $(jq length "$SCHED_FILE") == 1 ]]'
run cmd_schedule add bd --at "mon 15:00" --at "fri 18:30" --deployment "Windows 11" --before 5
check "second schedule, 5 min before" '[[ $rc == 0 ]] && grep -qx "OnCalendar=Fri \*-\*-\* 18:25:00" "$U/isardvdi-schedule-bd.timer"'

echo "== 3 edit, enable/disable, remove"
run cmd_schedule edit bd --at "wed 10:00"
check "--at replaces the slots" 'jq -e ".[1].slots == [\"Wed 10:00\"]" "$SCHED_FILE" >/dev/null && grep -qx "OnCalendar=Wed \*-\*-\* 09:55:00" "$U/isardvdi-schedule-bd.timer" && ! grep -q Fri "$U/isardvdi-schedule-bd.timer"'
run cmd_schedule edit aso --no-group
check "--no-group clears groups" 'jq -e ".[0].groups == []" "$SCHED_FILE" >/dev/null'
run cmd_schedule edit bd --rename gbd
check "--rename moves the timer" '[[ -f "$U/isardvdi-schedule-gbd.timer" && ! -e "$U/isardvdi-schedule-bd.timer" ]] && jq -e ".[1].name == \"gbd\"" "$SCHED_FILE" >/dev/null'
run cmd_schedule edit gbd --rename aso
check "rename onto an existing one refused" '[[ $rc != 0 ]]'
run cmd_schedule edit gbd
check "edit with nothing to change refused" '[[ $rc != 0 ]]'
run cmd_schedule disable gbd
check "disable: timer stopped, kept in the file" 'grep -q "disable --now isardvdi-schedule-gbd.timer" "$T/sysctl" && jq -e ".[1].enabled == false" "$SCHED_FILE" >/dev/null'
run cmd_schedule list
check "list marks it OFF, without a next run" 'grep -q "gbd   (OFF)" "$T/out" && grep -A5 "gbd   (OFF)" "$T/out" | grep -q "next:    -"'
run cmd_schedule enable gbd
check "enable: timer back" 'grep -q "restart isardvdi-schedule-gbd.timer" "$T/sysctl"'
run cmd_schedule remove gbd
check "remove: units and entry gone" '[[ ! -e "$U/isardvdi-schedule-gbd.timer" && ! -e "$U/isardvdi-schedule-gbd.service" ]] && [[ $(jq length "$SCHED_FILE") == 1 ]]'
run cmd_schedule remove gbd
check "removing it again: refused" '[[ $rc != 0 ]]'

echo "== 4 run (what the timer does)"
STATE=Stopped
run cmd_schedule run aso
check "starts the stopped desktops of its deployments" 'grep -q "PUT /api/v4/item/deployment/$D1/start" "$T/calls"'
check "logged as ok" 'tail -n 1 "$SCHED_LOG" | grep -q "\[aso\] ok: Start requested for 2"'
STATE=Started
run cmd_schedule run aso
check "idempotent: all running → no start sent, exit 0" '[[ $rc == 0 && ! -e "$T/calls" ]]'
check "logged as nothing to do" 'tail -n 1 "$SCHED_LOG" | grep -q "nothing to do"'
STATE=Stopped
cmd_schedule edit aso --group asix2 >/dev/null 2>&1
run cmd_schedule run aso
check "with a group: only that group's desktops" '[[ "$(cut -d" " -f1,2 "$T/calls")" == "PUT /api/v4/item/desktop/$S1/start" ]]'
cmd_schedule disable aso >/dev/null 2>&1
run cmd_schedule run aso
check "disabled: nothing sent, logged as skipped" '[[ $rc == 0 && ! -e "$T/calls" ]] && tail -n 1 "$SCHED_LOG" | grep -q skipped'
cmd_schedule enable aso >/dev/null 2>&1
using_apikey() { return 1; }
run cmd_schedule run aso
check "no API key: refused (never a Microsoft sign-in)" '[[ $rc != 0 && ! -e "$T/calls" ]] && grep -q "API key" "$T/out"'
using_apikey() { return 0; }
api_call() { echo "$1 $2" >> "$T/calls"; echo 'HTTP 500 boom' >&2; return 75; }
run cmd_schedule run aso
check "server error: exit != 0, logged FAILED" '[[ $rc != 0 ]] && tail -n 1 "$SCHED_LOG" | grep -q FAILED'
check "the log keeps a few lines" '[[ $(wc -l < "$SCHED_LOG") -ge 5 ]]'

echo "== 5 robustness (review findings)"
api_call() { echo "$1 $2 ${3:-}" >> "$T/calls"; echo '{}'; }
cmd_schedule enable aso >/dev/null 2>&1
rm -f "$SCHED_LOG" "$T/notify"
STATE=Stopped
run cmd_schedule run aso
check "first run ever (no log file yet): exit 0, logged, notified" '[[ $rc == 0 ]] && [[ -s "$SCHED_LOG" ]] && grep -q "|normal$" "$T/notify"'
date() { if [[ "$1" == +%u ]]; then echo 2; elif [[ "$1" == +%H ]]; then echo 16; elif [[ "$1" == +%M ]]; then echo 30; else command date "$@"; fi; }
run cmd_schedule run aso --from-timer
check "from the timer 92 min late (woke from sleep): skipped, nothing sent" '[[ $rc == 0 && ! -e "$T/calls" ]] && tail -n 1 "$SCHED_LOG" | grep -q "skipped: 92 min"'
date() { if [[ "$1" == +%u ]]; then echo 2; elif [[ "$1" == +%H ]]; then echo 14; elif [[ "$1" == +%M ]]; then echo 58; else command date "$@"; fi; }
run cmd_schedule run aso --from-timer
check "from the timer on time: starts" '[[ $rc == 0 ]] && grep -q "/start" "$T/calls"'
date() { if [[ "$1" == +%u ]]; then echo 2; elif [[ "$1" == +%H ]]; then echo 16; elif [[ "$1" == +%M ]]; then echo 30; else command date "$@"; fi; }
run cmd_schedule run aso
check "by hand, late or not: starts" '[[ $rc == 0 ]] && grep -q "/start" "$T/calls"'
unset -f date
# The network comes up only on the third try.
echo 0 > "$T/tries"
list_deployments_json() {
    local n; n=$(( $(cat "$T/tries") + 1 )); echo "$n" > "$T/tries"
    if (( n < 3 )); then echo "HTTP 000 on GET /x: network error" >&2; return 75; fi
    echo "[{\"id\":\"$D1\",\"name\":\"win server 25 Unique SID\",\"total_desktops\":10},{\"id\":\"$D2\",\"name\":\"Windows 11 uniquie SID ASIX2\",\"total_desktops\":10}]"
}
date() { if [[ "$1" == +%u ]]; then echo 2; elif [[ "$1" == +%H ]]; then echo 14; elif [[ "$1" == +%M ]]; then echo 58; else command date "$@"; fi; }
run cmd_schedule run aso --from-timer
unset -f date
check "from the timer: network down twice, retried, then ok" '[[ $rc == 0 && $(cat "$T/tries") -ge 3 ]] && tail -n 1 "$SCHED_LOG" | grep -q "ok:"'
echo 0 > "$T/tries"
run cmd_schedule run aso
check "by hand: no retry, fails at once" '[[ $rc != 0 && $(cat "$T/tries") == 1 ]]'
check "network down: logged FAILED with the cause" 'tail -n 1 "$SCHED_LOG" | grep -q "FAILED: HTTP 000"'
list_deployments_json() { echo "[{\"id\":\"$D1\",\"name\":\"win server 25 Unique SID\",\"total_desktops\":10}]"; }
rm -f "$T/notify"
run cmd_schedule run aso
check "a deployment deleted on the server: the other still starts" '[[ $rc == 0 ]] && grep -q "desktop/$S1/start" "$T/calls"'
check "... logged PARTIAL with its name, critical notification" 'tail -n 1 "$SCHED_LOG" | grep -q "PARTIAL: .*Windows 11 uniquie SID ASIX2" && grep -q "|critical$" "$T/notify"'
list_deployments_json() { echo "[{\"id\":\"$D1\",\"name\":\"win server 25 Unique SID\",\"total_desktops\":10},{\"id\":\"$D2\",\"name\":\"Windows 11 uniquie SID ASIX2\",\"total_desktops\":10}]"; }
api_call() { echo "$1 $2" >> "$T/calls"; echo 'HTTP 500 <a href="https://evil.example">Sign in again</a>' >&2; return 75; }
rm -f "$T/notify"
run cmd_schedule run aso
check "server text never reaches the notification" '[[ $rc != 0 ]] && ! grep -q "evil" "$T/notify" && grep -q "FAILED to start" "$T/notify"'
api_call() { echo "$1 $2 ${3:-}" >> "$T/calls"; echo '{}'; }
# One desktop refused, one started: PARTIAL, decided from the SUMMARY line, never shown.
cmd_schedule edit aso --group asix2 >/dev/null 2>&1
deployment_desktops_json() {
    [[ "$1" == "$D1" ]] && echo "[{\"id\":\"$S1\",\"user_name\":\"Pol A\",\"group_name\":\"26-27_ASIX2\",\"status\":\"Stopped\"},
                                {\"id\":\"$S2\",\"user_name\":\"Pau B\",\"group_name\":\"26-27_ASIX2\",\"status\":\"Stopped\"}]" || echo '[]'
}
api_call() { echo "$1 $2" >> "$T/calls"; if [[ "$2" == *"$S2"* ]]; then echo '{"description_code": "quota_exceeded"}' >&2; return 1; fi; echo '{}'; }
rm -f "$T/notify"
run cmd_schedule run aso
check "one of two refused: PARTIAL, critical" '[[ $rc == 0 ]] && tail -n 1 "$SCHED_LOG" | grep -q "PARTIAL: Start requested for 1 desktop(s), 1 failed" && grep -q "|critical$" "$T/notify"'
check "the SUMMARY line is never shown" '! grep -q "^SUMMARY" "$T/out"'
api_call() { echo "$1 $2 ${3:-}" >> "$T/calls"; echo '{}'; }
# A deployment whose name contains a stored id is not started by that id.
list_deployments_json() { echo "[{\"id\":\"$D1\",\"name\":\"w\"},{\"id\":\"$D2\",\"name\":\"Windows 11 uniquie SID ASIX2\"},{\"id\":\"d3333333-3333-3333-3333-333333333333\",\"name\":\"copy of $D1\"}]"; }
deployment_desktops_json() { echo "[{\"id\":\"$S1\",\"user_name\":\"Pol A\",\"group_name\":\"26-27_ASIX2\",\"status\":\"Stopped\"}]"; }
cmd_schedule edit aso --no-group >/dev/null 2>&1
run cmd_schedule run aso
check "an id never matches another deployment's name" '! grep -q "d3333333" "$T/calls"'
# systemd refuses: the schedule file is left as it was.
cp "$SCHED_FILE" "$T/before.json"
sched_systemctl() { echo "$*" >> "$T/sysctl"; [[ "$1" == enable ]] && { echo "Failed to enable unit" >&2; return 1; }; return 0; }
run cmd_schedule add bd2 --at "mon 15:00" --deployment "Windows 11"
check "systemd refuses the timer: refused, file unchanged, no unit left" '[[ $rc != 0 ]] && cmp -s "$SCHED_FILE" "$T/before.json" && [[ ! -e "$U/isardvdi-schedule-bd2.timer" ]] && grep -q "Failed to enable" "$T/out"'
sched_systemctl() { [[ "$1" == show-environment ]] && return 1; return 0; }
run cmd_schedule add bd2 --at "mon 15:00" --deployment "Windows 11"
check "no systemd user session: refused before saving" '[[ $rc != 0 ]] && cmp -s "$SCHED_FILE" "$T/before.json"'
sched_systemctl() { echo "$*" >> "$T/sysctl"; [[ "$1" == show ]] && echo "Tue 2026-11-03 14:58:00 CET"; return 0; }

echo "== 6 without systemd"
unset -f systemctl
# shellcheck disable=SC2123  # no PATH on purpose: no systemctl to find
( PATH=/nonexistent; cmd_schedule add nosd --at "mon 15:00" --deployment "win server" ) >/dev/null 2>&1; rc=$?
check "refused, and nothing saved" '[[ $rc != 0 ]] && ! jq -e "any(.[]; .name == \"nosd\")" "$SCHED_FILE" >/dev/null'
systemctl() { :; }

echo "== 7 dispatch"
check "schedule dispatched" 'grep -q "^    schedule|schedules|sched) cmd_schedule" "$REPO/bin/isardvdi"'

finish
