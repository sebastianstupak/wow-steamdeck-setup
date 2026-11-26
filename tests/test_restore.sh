#!/bin/bash
# Auto-heal restore: quarantined addons come back to AddOns only when it's safe (update done,
# Battle.net closed, past the settle delay, not thrashing).
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

log() { :; }
agent_pid() { echo "$AGENT"; }         # non-empty = Battle.net still updating
bnet_running() { return "${BNET:-1}"; } # 0 = running
q=$(mktemp -d); ad=$(mktemp -d)
QUARANTINE_DIR="$q"; ADDONS_DIR="$ad"; WOW_AUTOHEAL=1; RESTORE_DELAY=120
mkpack() { mkdir -p "$q/PackX"; : > "$q/PackX/f"; }
present() { [ -d "$q/PackX" ] && [ ! -d "$ad/PackX" ]; }   # still quarantined, not restored

mkpack
AGENT=999; BNET=1; HEAL_LAST=0; HEAL_STREAK=0; restore_quarantined
assert_ok present                                   # agent updating -> wait
AGENT="";  BNET=0; restore_quarantined
assert_ok present                                   # Battle.net running -> wait
AGENT="";  BNET=1; HEAL_LAST=$(date +%s); HEAL_STREAK=0; restore_quarantined
assert_ok present                                   # within settle delay -> wait
HEAL_LAST=0; HEAL_STREAK=2; restore_quarantined
assert_ok present                                   # thrashing -> leave quarantined
HEAL_LAST=0; HEAL_STREAK=0; restore_quarantined
assert_ok test -d "$ad/PackX"                       # safe -> restored to AddOns
assert_fail test -d "$q/PackX"                      # and gone from quarantine
finish
