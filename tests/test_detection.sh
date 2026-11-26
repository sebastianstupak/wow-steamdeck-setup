#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

# update_active: file whose last OP_UPDATE has no "completed" -> active
ad=$(mktemp -d)
cp fixtures/agent/Operations-active.log "$ad/Operations-1.log"
assert_ok update_active "$ad"
cp fixtures/agent/Operations-done.log "$ad/Operations-2.log"   # newer, completed
touch -d "+1 sec" "$ad/Operations-2.log" 2>/dev/null || sleep 1
assert_fail update_active "$ad"
assert_fail update_active /nonexistent

# login_needed: expired with NO later success -> needs login; expired THEN success -> fine
ld=$(mktemp -d)
cp fixtures/launcher/battle.net-expired.log "$ld/battle.net-1.log"
assert_ok login_needed "$ld"
cp fixtures/launcher/battle.net-ok.log "$ld/battle.net-1.log"
assert_fail login_needed "$ld"
finish
