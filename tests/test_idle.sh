#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

sf=$(mktemp)
date +%s > "$sf"
# fresh stamp -> ~0 idle seconds
v=$(idle_seconds "$sf"); [ "$v" -le 2 ] && echo "  ok: fresh idle=$v" || { echo "  FAIL: fresh idle=$v"; exit 1; }
# stamp 300s ago -> ~300 idle seconds
echo $(( $(date +%s) - 300 )) > "$sf"
v=$(idle_seconds "$sf"); [ "$v" -ge 290 ] && [ "$v" -le 310 ] && echo "  ok: old idle=$v" || { echo "  FAIL: old idle=$v"; exit 1; }
# missing stamp -> large number (unknown == not idle)
v=$(idle_seconds /nonexistent); [ "$v" -ge 999999 ] && echo "  ok: missing idle=$v" || { echo "  FAIL: missing idle=$v"; exit 1; }
# malformed stamp (non-numeric garbage) -> large number, not 0 and not a crash
printf 'not-a-number\n' > "$sf"
v=$(idle_seconds "$sf"); [ "$v" -ge 999999 ] && echo "  ok: malformed idle=$v" || { echo "  FAIL: malformed idle=$v"; exit 1; }

# should_prewarm: enabled, no WoW, idle past threshold -> yes
assert_ok   should_prewarm 1 0 200 180
assert_fail should_prewarm 0 0 200 180   # disabled
assert_fail should_prewarm 1 1 200 180   # WoW running
assert_fail should_prewarm 1 0 100 180   # not idle long enough
finish
