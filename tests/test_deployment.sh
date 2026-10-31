#!/usr/bin/env bash
# Tests for 'deployment', '<deployment> <student>' targets, 'bastion' and ssh through the bastion.
# Server mocked: every API call is logged to $T/calls as "METHOD PATH BODY".
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
D1=d1111111-1111-1111-1111-111111111111 D2=d2222222-2222-2222-2222-222222222222
S1=51111111-1111-1111-1111-111111111111 S2=52222222-2222-2222-2222-222222222222
S3=53333333-3333-3333-3333-333333333333 MINE=a1111111-1111-1111-1111-111111111111
TG=7a111111-1111-1111-1111-111111111111

list_deployments_json() {
    echo "[{\"id\":\"$D1\",\"name\":\"Ubuntu 24 server ASIX.1\"},{\"id\":\"$D2\",\"name\":\"Ubuntu 26 Server ASIX2\"}]"
}
deployment_desktops_json() {
    case "$1" in
        "$D1") echo "[{\"id\":\"$S1\",\"user_name\":\"Abdellah A\",\"group_name\":\"26-27_ASIX1\",\"status\":\"Started\",\"ip\":\"10.2.132.67\"},
                     {\"id\":\"$S2\",\"user_name\":\"Alex E\",\"group_name\":\"26-27_ASIX1\",\"status\":\"Stopped\",\"ip\":null},
                     {\"id\":\"$S3\",\"user_name\":\"Teacher T\",\"group_name\":\"docents\",\"status\":\"Stopped\",\"ip\":null}]" ;;
        "$D2") echo "[]" ;;
    esac
}
list_desktops_json() { echo "[{\"id\":\"$MINE\",\"name\":\"coolify\",\"status\":\"Started\",\"ip\":\"10.2.0.9\"}]"; }
desktop_detail_json() { echo "{\"name\":\"Ubuntu 24 server\",\"status\":\"Started\",\"ip\":null}"; }
BASTION_ACTIVE='{"bastion_enabled":true,"ssh":{"enabled":true,"port":22},"id":"'$TG'","bastion_domain":"bastion.example.cat","bastion_ssh_port":"443"}'
PROFILE_KEY='{"ssh_key":"ssh-ed25519 AAAA x"}'
api_call() {
    echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET "*/bastion/active)            echo "$BASTION_ACTIVE" ;;
        "GET /api/v4/item/user/bastion-ssh-key") echo "$PROFILE_KEY" ;;
        "GET /api/v4/item/deployment/"*/bastion) echo '{"ssh":{"enabled":false,"port":2222},"http":{"enabled":true,"http_port":80,"https_port":443}}' ;;
        "GET /api/v4/item/desktop/"*/bastion) echo '{"ssh":{"enabled":false,"port":22,"authorized_keys":["ssh-ed25519 KEEP me"]},"http":{"enabled":false},"domains":["d.example"]}' ;;
        *) echo '{}' ;;
    esac
}
sleep() { :; }
# Runs "$@" in a new session (no terminal to confirm on): the CLI loaded as usual, then this
# test's mocks and variables on top.
no_tty() {
    setsid -w bash -c 'source "$1"; set +e; source /dev/stdin; shift; "$@"' _ "$REPO/bin/isardvdi" "$@" \
        <<< "$(declare -f; declare -p T TG S1 S2 S3 D1 D2 MINE BASTION_ACTIVE PROFILE_KEY 2>/dev/null)"
}
run() { rm -f "$T/calls"; ( set -e; "$@" ) >"$T/out" 2>&1; rc=$?; }
calls() { cut -d' ' -f1,2 "$T/calls" 2>/dev/null | tr '\n' ' '; }

echo "== 1 deployment: whole deployments in one request"
run cmd_deployment start "ASIX.1" -y
check "start: one bulk request" '[[ $rc == 0 && "$(calls)" == "PUT /api/v4/item/deployment/$D1/start " ]]'
check "start: counts only stopped desktops (2 of 3)" 'grep -q "Start 2 desktop" "$T/out"'
run cmd_deployment stop "ASIX.1" -y
check "stop: bulk request with force false" 'grep -qx "PUT /api/v4/item/deployment/$D1/stop {\"force\":false}" "$T/calls"'
run cmd_deployment stop "ASIX.1" -y --force
check "stop --force: force true" 'grep -qx "PUT /api/v4/item/deployment/$D1/stop {\"force\":true}" "$T/calls"'
run cmd_deployment start "asix" -y
check "a query matching two deployments acts on the ones with work to do" '[[ "$(calls)" == "PUT /api/v4/item/deployment/$D1/start " ]] && grep -q "ASIX2" "$T/out"'

echo "== 2 deployment: groups go desktop by desktop"
run cmd_deployment start "ASIX.1" --group asix1 -y
check "--group: only the group's stopped desktop" '[[ "$(calls)" == "PUT /api/v4/item/desktop/$S2/start " ]]'
check "--group: plan names the group" 'grep -q "groups: 26-27_ASIX1" "$T/out"'
run cmd_deployment stop "ASIX.1" --group ASIX1 -y
check "--group stop: only the started one" '[[ "$(calls)" == "PUT /api/v4/item/desktop/$S1/stop " ]]'
run cmd_deployment start "ASIX.1" --group nobody -y
check "unknown group: refused, lists the groups, no call" '[[ $rc != 0 && ! -e "$T/calls" ]] && grep -q "docents" "$T/out"'
run cmd_deployment extend "ASIX.1"
check "extend: started desktops only, no confirmation needed" '[[ $rc == 0 && "$(calls)" == "PUT /api/v4/item/desktop/$S1/extend-timeout " ]]'

echo "== 3 deployment: safety"
rm -f "$T/calls"
no_tty cmd_deployment stop "ASIX.1" >"$T/out" 2>&1; rc=$?
check "no terminal and no -y: refused, nothing sent" '[[ $rc != 0 && ! -e "$T/calls" ]] && grep -q -- "-y" "$T/out"'
run cmd_deployment stop "nothing-like-this" -y
check "no matching deployment: refused" '[[ $rc != 0 && ! -e "$T/calls" ]]'
run cmd_deployment start "ASIX.1" --force -y
check "--force refused for start" '[[ $rc != 0 && ! -e "$T/calls" ]]'
run cmd_deployment frobnicate "ASIX.1"
check "unknown subcommand: usage" '[[ $rc != 0 ]] && grep -q "Usage: isardvdi deployment" "$T/out"'
api_call() { echo "$1 $2 ${3:-}" >> "$T/calls"; echo 'HTTP 403 {"description_code": "desktop_extend_not_allowed"}' >&2; return 1; }
run cmd_deployment extend "ASIX.1"
check "all failed: exit 1, the reason per student" '[[ $rc != 0 ]] && grep -q "Abdellah A: desktop_extend_not_allowed" "$T/out"'

echo "== 4 <deployment> <student> targets"
api_call() { echo "$1 $2 ${3:-}" >> "$T/calls"; echo '{}'; }
run cmd_stop "ASIX.1" alex
check "stop <dep> <student>" '[[ "$(calls)" == "PUT /api/v4/item/desktop/$S2/stop " ]]'
run cmd_stop --force "ASIX.1" alex
check "stop --force before the target still works" '[[ $rc == 0 ]] && grep -q "Force-stop" "$T/out"'
run cmd_start "ASIX.1" abdellah
check "start a student's: waits for Started from the deployment list" '[[ $rc == 0 ]] && grep -q "Started: ip=10.2.132.67" "$T/out"'
run cmd_status "ASIX.1" abdellah
check "status shows the student and the IP from the deployment list" 'grep -q "Abdellah A" "$T/out" && grep -q "10.2.132.67" "$T/out"'
run cmd_extend "ASIX.1" nobody-here
check "unknown student: refused, no call" '[[ $rc != 0 && ! -e "$T/calls" ]]'
run cmd_start a b c
check "three words: usage" '[[ $rc != 0 ]] && grep -q "Usage: isardvdi start" "$T/out"'

echo "== 5 ssh through the bastion"
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$T/ssh-args"
EOF
chmod 755 "$T/bin/ssh"
api_call() {
    echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET "*/bastion/active) echo "$BASTION_ACTIVE" ;;
        "GET /api/v4/item/user/bastion-ssh-key") echo "$PROFILE_KEY" ;;
        *) echo '{}' ;;
    esac
}
sshrun() { rm -f "$T/ssh-args" "$T/calls"; ( set -e; PATH="$T/bin:$PATH"; cmd_ssh "$@" ) >"$T/out" 2>&1; rc=$?; }
sshrun "ASIX.1" abdellah -- hostname
check "student: ssh to target@bastion -p 443, command passed" \
    '[[ $rc == 0 ]] && [[ "$(tr "\n" " " < "$T/ssh-args")" == "-p 443 -o ForwardAgent=no -o ForwardX11=no $TG@bastion.example.cat hostname " ]]'
sshrun "ASIX.1" abdellah -l root
check "-l refused through the bastion" '[[ $rc != 0 && ! -e "$T/ssh-args" ]]'
sshrun coolify uptime
check "old 'ssh desktop command' form: hint to use --" '[[ $rc != 0 && ! -e "$T/ssh-args" ]] && grep -q "coolify -- uptime" "$T/out"'
for bad in '"bastion_domain":"evil.example -oProxyCommand=x"' '"bastion_ssh_port":"99999"' '"id":"../x"' '"bastion_domain":"-oProxyCommand=x"'; do
    key=${bad%%:*}
    BASTION_ACTIVE=$(jq -c ". + {$bad}" <<< '{"bastion_enabled":true,"ssh":{"enabled":true,"port":22},"id":"'$TG'","bastion_domain":"bastion.example.cat","bastion_ssh_port":"443"}')
    sshrun "ASIX.1" abdellah
    check "server value $key refused before ssh" '[[ $rc != 0 && ! -e "$T/ssh-args" ]]'
done
BASTION_ACTIVE='{"bastion_enabled":true,"ssh":{"enabled":false},"id":"'$TG'","bastion_domain":"bastion.example.cat","bastion_ssh_port":"443"}'
sshrun "ASIX.1" abdellah
check "bastion off: says how to switch it on" '[[ $rc != 0 && ! -e "$T/ssh-args" ]] && grep -q "isardvdi bastion on $D1" "$T/out"'
BASTION_ACTIVE='{"exists":false,"ssh":{"enabled":false,"port":22},"bastion_enabled":false}'
sshrun "ASIX.1" abdellah
check "no bastion target yet: says how to switch it on" '[[ $rc != 0 && ! -e "$T/ssh-args" ]] && grep -q "isardvdi bastion on" "$T/out"'
BASTION_ACTIVE='{"bastion_enabled":true,"ssh":{"enabled":true,"port":22},"id":"'$TG'","bastion_domain":"bastion.example.cat","bastion_ssh_port":"443"}'
PROFILE_KEY='{"ssh_key":""}'
sshrun "ASIX.1" abdellah
check "no profile key: says how to add one" '[[ $rc != 0 && ! -e "$T/ssh-args" ]] && grep -q "bastion key" "$T/out"'
PROFILE_KEY='{"ssh_key":"ssh-ed25519 AAAA x"}'
deployment_desktops_json() { echo "[{\"id\":\"$S1\",\"user_name\":\"Abdellah A\",\"status\":\"Started\",\"ip\":null}]"; }
START_TIMEOUT=0 sshrun "ASIX.1" abdellah
check "no VPN IP: explains the WireGuard card" '[[ $rc != 0 && ! -e "$T/ssh-args" ]] && grep -q "WireGuard" "$T/out"'

echo "== 5b the bastion host is remembered"
check "first use remembered" '[[ "$(cat "$BASTION_HOST_FILE")" == "bastion.example.cat:443" ]]'
BASTION_ACTIVE='{"bastion_enabled":true,"ssh":{"enabled":true,"port":22},"id":"'$TG'","bastion_domain":"evil.example.org","bastion_ssh_port":"443"}'
deployment_desktops_json() { echo "[{\"id\":\"$S1\",\"user_name\":\"Abdellah A\",\"status\":\"Started\",\"ip\":\"10.2.1.1\"}]"; }
sh_tofu() { sshrun "ASIX.1" abdellah; cat "$T/out"; return $rc; }
no_tty sh_tofu >"$T/tofu" 2>&1; rc=$?
check "a different bastion host, no terminal to confirm: refused, ssh not run" '[[ $rc != 0 && ! -e "$T/ssh-args" ]] && grep -q "different bastion" "$T/tofu" && grep -q "add -y\|No terminal" "$T/tofu" && [[ "$(cat "$BASTION_HOST_FILE")" == "bastion.example.cat:443" ]]'
BASTION_ACTIVE='{"bastion_enabled":true,"ssh":{"enabled":true,"port":22},"id":"'$TG'","bastion_domain":"bastion.example.cat","bastion_ssh_port":"0443"}'
sshrun "ASIX.1" abdellah
check "a port with a leading zero is read as decimal 443" '[[ $rc == 0 ]] && grep -qx 443 <(sed -n 2p "$T/ssh-args")'

echo "== 5c review fixes: matching, waits, errors"
list_deployments_json() {
    echo "[{\"id\":\"$D1\",\"name\":\"Ubuntu 24 server ASIX.1\"},{\"id\":\"$D2\",\"name\":\"copy of $D1\"}]"
}
check "an id picks that deployment only" '[[ $(deployments_matching "$D1" | jq length) == 1 ]]'
check "a name still picks every deployment containing it" '[[ $(deployments_matching "u" | jq length) == 1 && $(deployments_matching "1" | jq length) == 2 ]]'
check "an exact student name wins over longer ones" '[[ "$(echo "[{\"id\":\"$S1\",\"user_name\":\"Alex\"},{\"id\":\"$S2\",\"user_name\":\"Alexandra B\"}]" | match_one student alex user_name)" == "$S1" ]]'
list_deployments_json() {
    echo "[{\"id\":\"$D1\",\"name\":\"Ubuntu 24 server ASIX.1\"},{\"id\":\"$D2\",\"name\":\"Ubuntu 26 Server ASIX2\"}]"
}
# --wait waits only on the desktops whose request went through.
deployment_desktops_json() {
    [[ "$1" == "$D1" ]] && echo "[{\"id\":\"$S1\",\"user_name\":\"A\",\"group_name\":\"g1\",\"status\":\"$(cat "$T/s1")\"},
                                {\"id\":\"$S2\",\"user_name\":\"B\",\"group_name\":\"g1\",\"status\":\"Stopped\"}]" || echo '[]'
}
echo Stopped > "$T/s1"
api_call() { echo "$1 $2" >> "$T/calls"; if [[ "$2" == *"$S2"* ]]; then echo '{"description_code": "quota_exceeded"}' >&2; return 1; fi; echo Started > "$T/s1"; echo '{}'; }
START_TIMEOUT=5 run cmd_deployment start "ASIX.1" --group g1 --wait -y
check "--wait: a refused desktop isn't waited for" '[[ $rc == 0 ]] && grep -q "All Started" "$T/out" && grep -q "B: quota_exceeded" "$T/out"'
echo Failed > "$T/s1"
api_call() { echo "$1 $2" >> "$T/calls"; echo '{}'; }
START_TIMEOUT=0 run cmd_deployment start "ASIX.1" --group g1 --wait -y
check "--wait: a desktop that was already Failed is not taken as done" '[[ $rc != 0 ]] && grep -q "not Started yet" "$T/out"'
api_call() { echo 'HTTP 404 on PUT /x: <html>Not Found</html>' >&2; return 1; }
run cmd_extend coolify
check "extend: an error without a code still says why" '[[ $rc != 0 ]] && grep -q "404" "$T/out"'

echo "== 6 bastion on/off/key"
deployment_desktops_json() { echo "[{\"id\":\"$S1\",\"user_name\":\"Abdellah A\",\"status\":\"Started\",\"ip\":\"10.2.1.1\"}]"; }
api_call() {
    echo "$1 $2 ${3:-}" >> "$T/calls"
    case "$1 $2" in
        "GET /api/v4/item/deployment/"*/bastion) echo '{"ssh":{"enabled":false,"port":2222},"http":{"enabled":true,"http_port":80,"https_port":443}}' ;;
        "GET /api/v4/item/desktop/"*/bastion) echo '{"ssh":{"enabled":false,"port":22,"authorized_keys":["ssh-ed25519 KEEP me"]},"http":{"enabled":false},"domains":["d.example"]}' ;;
        *) echo '{}' ;;
    esac
}
run cmd_bastion on "ASIX.1"
check "deployment on: keeps its port and HTTP settings" \
    'grep -qx "PUT /api/v4/item/deployment/$D1/bastion {\"ssh\":{\"enabled\":true,\"port\":2222},\"http\":{\"enabled\":true,\"http_port\":80,\"https_port\":443}}" "$T/calls"'
run cmd_bastion off "ASIX.1" --port 22
check "deployment off --port 22" 'grep -q "PUT /api/v4/item/deployment/$D1/bastion {\"ssh\":{\"enabled\":false,\"port\":22}" "$T/calls"'
run cmd_bastion on --desktop coolify
check "own desktop on: keeps its keys and domains" \
    'grep -q "PUT /api/v4/item/desktop/$MINE/bastion .*\"enabled\":true.*KEEP me.*\"domains\":\[\"d.example\"\]" "$T/calls"'
run cmd_bastion on --desktop "$S1"
check "a student's desktop with --desktop: refused, no PUT" '[[ $rc != 0 ]] && ! grep -q "^PUT" "$T/calls"'
run cmd_bastion on "ASIX.1" --port 70000
check "bad --port refused" '[[ $rc != 0 && ! -e "$T/calls" ]]'
ssh-keygen -q -t ed25519 -N "" -C selftest -f "$T/k" >/dev/null
run cmd_bastion key "$T/k"
check "private key file refused, nothing sent" '[[ $rc != 0 && ! -e "$T/calls" ]]'
run cmd_bastion key "$T/k.pub"
check "public key sent as ssh_key" 'grep -q "PUT /api/v4/item/user/bastion-ssh-key {\"ssh_key\":\"ssh-ed25519 .* selftest\"}" "$T/calls"'
printf 'ssh-ed25519 AAAA a\nssh-ed25519 BBBB b\n' > "$T/two.pub"
run cmd_bastion key "$T/two.pub"
check "two keys in one file refused" '[[ $rc != 0 && ! -e "$T/calls" ]]'

echo "== 7 dispatch"
check "deployment dispatched" 'grep -q "^    deployment|dep)  *cmd_deployment" "$REPO/bin/isardvdi"'
check "bastion dispatched" 'grep -q "^    bastion)  *cmd_bastion" "$REPO/bin/isardvdi"'

finish
