#!/usr/bin/env bash
# 'isardvdi tunnel': port specs, the local port check, and the ssh command it runs (VPN or
# bastion), with the server and ssh mocked.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
D1=11111111-1111-1111-1111-111111111111   # your desktop "athena"
S1=33333333-3333-3333-3333-333333333333   # a student's desktop in deployment "ASIX.1"
DEP=44444444-4444-4444-4444-444444444444
TG=22222222-2222-2222-2222-222222222222   # its bastion target
IP=10.2.54.159
list_desktops_json() { echo "[{\"id\":\"$D1\",\"name\":\"athena\",\"status\":\"Started\",\"ip\":\"$IP\"}]"; }
list_deployments_json() { echo "[{\"id\":\"$DEP\",\"name\":\"ASIX.1\"}]"; }
deployment_desktops_json() { echo "[{\"id\":\"$S1\",\"user_name\":\"Abdellah A\",\"status\":\"Started\",\"ip\":\"10.2.1.1\"}]"; }
api_call() {
    echo "$1 $2" >> "$T/calls"
    case "$1 $2" in
        "GET "*/bastion/active) echo '{"bastion_enabled":true,"ssh":{"enabled":true},"id":"'$TG'","bastion_domain":"bastion.example.cat","bastion_ssh_port":"443"}' ;;
        "GET /api/v4/item/user/bastion-ssh-key") echo '{"ssh_key":"ssh-ed25519 AAAA x"}' ;;
        *) echo '{}' ;;
    esac
}
printf 'bastion.example.cat:443\n' > "$BASTION_HOST_FILE"
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$T/ssh-args"
EOF
chmod 755 "$T/bin/ssh"
run() { rm -f "$T/ssh-args" "$T/calls"; ( set -e; PATH="$T/bin:$PATH"; cmd_tunnel "$@" ) >"$T/out" 2>&1; rc=$?; }
args() { tr '\n' ' ' < "$T/ssh-args"; }
# Free local ports (a real tunnel may hold 15432 on this computer).
read -r P1 P2 P3 < <(python3 -c 'import socket
ss=[socket.socket() for _ in range(3)]
[s.bind(("127.0.0.1",0)) for s in ss]
print(*[s.getsockname()[1] for s in ss])')
PRE="-N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

echo "== 1 port specs"
run athena $P1:5432 --bastion
check "LOCAL:PORT -> localhost on the desktop, 127.0.0.1 only, before the destination" \
    '[[ $rc == 0 && "$(args)" == "-p 443 -o ForwardAgent=no -o ForwardX11=no $PRE -L 127.0.0.1:$P1:localhost:5432 $TG@bastion.example.cat " ]]'
check "says what is forwarded" 'grep -q "localhost:$P1 -> localhost:5432" "$T/out"'
run athena $P2 $P3:172.18.0.2:5432 --bastion
check "PORT and LOCAL:HOST:PORT, several at once" \
    '[[ $rc == 0 ]] && [[ "$(args)" == *"-L 127.0.0.1:$P2:localhost:$P2 -L 127.0.0.1:$P3:172.18.0.2:5432 $TG@"* ]]'
run athena $P1:05432 --bastion
check "leading zeros read as decimal" '[[ $rc == 0 ]] && [[ "$(args)" == *"-L 127.0.0.1:$P1:localhost:5432 "* ]]'
for bad in 0 70000 15432: :5432 1:2:3:4 "1:-oProxyCommand=x:22" "1:a b:22" 5432x; do
    run athena "$bad" --bastion
    check "bad spec \"$bad\": refused before any call" '[[ $rc != 0 && ! -e "$T/ssh-args" && ! -e "$T/calls" ]]'
done
run athena $P1 $P1:5432 --bastion
check "same local port twice: refused" '[[ $rc != 0 && ! -e "$T/ssh-args" ]] && grep -q "given twice" "$T/out"'
run athena
check "no port: usage" '[[ $rc != 0 ]] && grep -q "Usage: isardvdi tunnel" "$T/out"'
run athena 5432 --what
check "unknown flag: refused" '[[ $rc != 0 && ! -e "$T/ssh-args" ]]'

echo "== 2 a local port already in use"
port_file="$T/port"
python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(30)' "$port_file" &
lis=$!
for _ in $(seq 50); do [[ -s "$port_file" ]] && break; sleep 0.1; done
busy=$(cat "$port_file")
run athena "$busy:5432" --bastion
check "refused before connecting, says why" '[[ $rc != 0 && ! -e "$T/ssh-args" && ! -e "$T/calls" ]] && grep -q "already in use" "$T/out"'
kill "$lis" 2>/dev/null; wait "$lis" 2>/dev/null

echo "== 3 targets"
run "ASIX.1" abdellah $P1:3306
check "a student's desktop: through the bastion, no --bastion needed" \
    '[[ $rc == 0 ]] && [[ "$(args)" == *"-L 127.0.0.1:$P1:localhost:3306 $TG@bastion.example.cat " ]]'
run "ASIX.1" abdellah 13306:3306 -l root
check "-l through the bastion: refused" '[[ $rc != 0 && ! -e "$T/ssh-args" ]]'
if timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null; then
    IP=127.0.0.1
    run athena $P1:5432 -l postgres
    check "your desktop over the VPN: user, host key alias, forwards" \
        '[[ $rc == 0 && "$(args)" == "-o HostKeyAlias=isardvdi-$D1 -o ForwardAgent=no -o ForwardX11=no $PRE -L 127.0.0.1:$P1:localhost:5432 postgres@127.0.0.1 " ]]'
else
    skip "VPN path (needs something listening on 127.0.0.1:22 to stand in for the desktop)"
fi

echo "== 4 plain ssh is unchanged"
rm -f "$T/ssh-args"; ( set -e; PATH="$T/bin:$PATH"; cmd_ssh athena --bastion -- uptime ) >"$T/out" 2>&1; rc=$?
check "ssh --bastion: no tunnel options" '[[ $rc == 0 && "$(args)" == "-p 443 -o ForwardAgent=no -o ForwardX11=no $TG@bastion.example.cat uptime " ]]'

finish
