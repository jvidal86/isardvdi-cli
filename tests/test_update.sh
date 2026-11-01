#!/usr/bin/env bash
# 'isardvdi update' and 'version', and install.sh pinning a version to its commit, against a fake
# GitHub: nothing here downloads or installs anything for real.
# shellcheck source=tests/common.sh
source "$(dirname "$0")/common.sh"

OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222

echo "== install.sh records the commit it installed"
# A fake curl serving this checkout as GitHub: the API answers $T/api-sha (or fails without it),
# raw files come from the repo. Every URL is logged.
mkdir -p "$T/gh"
cat > "$T/gh/curl" <<FAKE
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; https://*) url=\$1; shift ;; *) shift ;; esac; done
echo "\$url" >> "$T/gh.log"
case "\$url" in
    https://api.github.com/*) [ -f "$T/api-sha" ] && cat "$T/api-sha" || exit 22 ;;
    https://raw.githubusercontent.com/*) cp "$REPO/\${url#https://raw.githubusercontent.com/jvidal86/isardvdi-cli/*/}" "\$out" ;;
esac
FAKE
chmod 755 "$T/gh/curl"
install_cli() { PATH="$T/gh:$PATH" BIN_DIR="$T/inst/bin" DATA_DIR="$T/inst/share" sh "$REPO/install.sh" > "$T/inst.out" 2>&1; }

printf '%s' "$NEW" > "$T/api-sha"; : > "$T/gh.log"
check "main is pinned to its commit" 'install_cli && [[ "$(cat "$T/inst/share/installed-commit")" == "$NEW" ]]'
check "every file came from that commit" '! grep raw.githubusercontent "$T/gh.log" | grep -vq "/$NEW/"'
check "the program is the one in the repo" 'cmp -s "$T/inst/bin/isardvdi" "$REPO/bin/isardvdi"'
check "a first install says what to do next" 'grep -q "next: run" "$T/inst.out"'
rm -f "$T/api-sha"
check "no API answer: installs main, records no commit" \
    'install_cli && [[ ! -f "$T/inst/share/installed-commit" ]] && grep -q "downloading (main)" "$T/inst.out"'
check "an exact commit is recorded as is" \
    'ISARDVDI_REF=$OLD install_cli && [[ "$(cat "$T/inst/share/installed-commit")" == "$OLD" ]] && grep -q "/$OLD/" "$T/gh.log"'
check "an update doesn't say 'next: run init'" \
    'printf %s "$NEW" > "$T/api-sha"; ISARDVDI_UPDATING=1 install_cli && ! grep -q "next: run" "$T/inst.out"'

echo "== isardvdi update (an installed copy)"
real_self_git_dir=$(declare -f self_git_dir)
HELPER="$T/share/sso_login.py"; INSTALLED_COMMIT_FILE="$T/share/installed-commit"; mkdir -p "$T/share"
self_git_dir() { return 1; }
self_path() { echo "$T/bin-here/isardvdi"; }
LATEST=$NEW
# GitHub: the newest commit, what changed, and an installer that records how it was run.
curl() {
    local out="" url="" a
    for a in "$@"; do [[ "$a" == https://* ]] && url=$a; done
    while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out=$2; shift; done
    case "$url" in
        */commits/main) [[ -n "$LATEST" ]] && printf '%s' "$LATEST" ;;
        */compare/*) printf '{"commits":[{"commit":{"message":"Add vpn status\\n\\nbody"}},{"commit":{"message":"Fix \\u001b[31mred"}}]}' ;;
        */install.sh) printf '#!/bin/sh\necho "REF=$ISARDVDI_REF BIN=$BIN_DIR DATA=$DATA_DIR UPD=$ISARDVDI_UPDATING" > "%s"\nexit ${FAIL:-0}\n' "$T/ran" > "$out" ;;
        *) return 22 ;;
    esac
}
run() { rm -f "$T/ran"; "$@" </dev/null >"$T/out" 2>&1; }
out() { cat "$T/out"; }

printf '%s\n' "$NEW" > "$INSTALLED_COMMIT_FILE"
check "up to date: nothing installed" '( run cmd_update ) && out | grep -q "up to date (2222222)" && [[ ! -f "$T/ran" ]]'
printf '%s\n' "$OLD" > "$INSTALLED_COMMIT_FILE"
check "--check only says there is one, and what's new" \
    '( run cmd_update --check ) && out | grep -q "1111111 -> 2222222" && out | grep -q "  - Add vpn status$" && [[ ! -f "$T/ran" ]]'
check "commit subjects can't send terminal escapes" '! out | grep -q $'"'"'\e'"'"
check "update runs that commit's installer over this installation" \
    '( run cmd_update ) && [[ "$(cat "$T/ran")" == "REF=$NEW BIN=$T/bin-here DATA=$T/share UPD=1" ]] && out | grep -q "Updated to 2222222"'
check "a failed installer is reported" '! ( FAIL=1 run cmd_update ) && out | grep -q "The update failed"'
LATEST=""
check "no network: says so" '! ( run cmd_update ) && out | grep -q "Couldn.t ask GitHub"'
LATEST=$NEW; rm -f "$INSTALLED_COMMIT_FILE"
check "unknown version: installs the latest" '( run cmd_update ) && out | grep -q "wasn.t recorded" && [[ -f "$T/ran" ]]'
check "unknown flag" '! ( run cmd_update --now )'

echo "== version"
check "unknown" '[[ "$(cmd_version)" == *"not recorded"* ]]'
printf '%s\n' "$NEW" > "$INSTALLED_COMMIT_FILE"
check "installed" '[[ "$(cmd_version)" == "isardvdi 2222222" ]]'

echo "== the daily notice"
stderr_is_terminal() { return 0; }
printf '%s\n' "$OLD" > "$INSTALLED_COMMIT_FILE"; rm -f "$UPDATE_STAMP"
check "a newer version is mentioned" 'update_notice 2>&1 | grep -q "isardvdi update"'
check "at most once a day" '[[ -z "$(update_notice 2>&1)" ]]'
rm -f "$UPDATE_STAMP"
check "ISARDVDI_UPDATE_CHECK=0 turns it off" '[[ -z "$(ISARDVDI_UPDATE_CHECK=0 update_notice 2>&1)" ]]'
rm -f "$UPDATE_STAMP"; printf '%s\n' "$NEW" > "$INSTALLED_COMMIT_FILE"
check "up to date: silent" '[[ -z "$(update_notice 2>&1)" ]]'
rm -f "$UPDATE_STAMP"; LATEST=""; printf '%s\n' "$OLD" > "$INSTALLED_COMMIT_FILE"
check "no network: silent" '[[ -z "$(update_notice 2>&1)" ]]'
stderr_is_terminal() { return 1; }; rm -f "$UPDATE_STAMP"; LATEST=$NEW
check "not in a terminal (timers, the tray): silent" '[[ -z "$(update_notice 2>&1)" ]]'
unset -f curl

echo "== isardvdi update (a git clone)"
if command -v git >/dev/null 2>&1; then
    g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
    g init -q --bare "$T/up.git"; g clone -q "$T/up.git" "$T/w1"; mkdir -p "$T/w1/bin"; echo v1 > "$T/w1/bin/isardvdi"
    g -C "$T/w1" add -A; g -C "$T/w1" commit -qm one; g -C "$T/w1" push -q origin HEAD:main
    g clone -q "$T/up.git" "$T/clone"
    echo v2 > "$T/w1/bin/isardvdi"; g -C "$T/w1" commit -qam "Second version"; g -C "$T/w1" push -q origin HEAD:main
    eval "$real_self_git_dir"
    self_path() { echo "$T/clone/bin/isardvdi"; }
    check "--check lists the new commits, changes nothing" \
        '( run cmd_update --check ) && out | grep -q "  - Second version" && [[ "$(cat "$T/clone/bin/isardvdi")" == v1 ]]'
    check "update pulls" '( run cmd_update ) && [[ "$(cat "$T/clone/bin/isardvdi")" == v2 ]] && out | grep -q "Updated to"'
    check "then it's up to date" '( run cmd_update ) && out | grep -q "up to date"'
    check "version names the clone" '[[ "$(cmd_version)" == *"git clone: $T/clone"* ]]'
else
    skip "git clone update (no git)"
fi

finish
