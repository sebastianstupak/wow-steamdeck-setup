#!/bin/bash
# login_needed: the saved Battle.net session expired and needs a human sign-in.
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

ld=$(mktemp -d)
# expired marker with NO later success -> needs login
cp fixtures/launcher/battle.net-expired.log "$ld/battle.net-1.log"
assert_ok login_needed "$ld"
# expired THEN a later success -> fine (self-recovered)
cp fixtures/launcher/battle.net-ok.log "$ld/battle.net-1.log"
assert_fail login_needed "$ld"
# no launcher log at all -> not "needs login"
assert_fail login_needed /nonexistent
finish
