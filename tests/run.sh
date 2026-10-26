#!/usr/bin/env bash
# Runs every test on this computer. They use a throwaway config dir and fake keys, and never
# talk to a server. If a keyring is running, a few tests store and remove an item "selftest".
# Ubuntu 22.04 / WSL compatibility (needs Docker): tests/ubuntu-22.04.sh
cd "$(dirname "$0")" || exit 1
failed=()
for t in test_*.sh; do
    echo "##### $t"
    bash "$t" || failed+=("$t")
    echo
done
if (( ${#failed[@]} )); then echo "FAILED: ${failed[*]}"; exit 1; fi
echo "All tests passed."
