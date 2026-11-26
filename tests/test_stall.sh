#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

ad=$(mktemp -d)
cp fixtures/agent/Operations-active.log "$ad/Operations-1.log"
# Fresh mtime -> active but NOT stalled
assert_fail update_stalled "$ad" 150
# Old mtime -> active AND frozen -> stalled
touch -d "400 seconds ago" "$ad/Operations-1.log"
assert_ok update_stalled "$ad" 150
# Not active (completed) -> never stalled even if old
cp fixtures/agent/Operations-done.log "$ad/Operations-1.log"
touch -d "400 seconds ago" "$ad/Operations-1.log"
assert_fail update_stalled "$ad" 150
finish
