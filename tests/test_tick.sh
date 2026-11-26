#!/bin/bash
# Integration test for autoupdate_tick: stub every side-effecting helper and record which
# actions fire, so we verify the DECISION matrix (recover / launch / kill) with no real
# processes and no Deck. idle_seconds + should_prewarm are the REAL functions (already
# tested) so the wiring is exercised end-to-end at the decision level.
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

ACTIONS=""
log() { :; }
start_idle_watch() { :; }                 # never spawn python in tests
prewarm_launch()        { ACTIONS="$ACTIONS launch"; }
prewarm_kill()          { ACTIONS="$ACTIONS kill"; }
recover_stalled_update(){ ACTIONS="$ACTIONS recover"; }
prewarm_running() { return $PR; }          # 0 => running (true)
update_stalled()  { return $US; }          # 0 => stalled (true)
update_active()   { return $UA; }          # 0 => active  (true)
prewarm_age()     { echo "$AGE"; }
IDLE_PID=fake
INPUT_STAMP=$(mktemp)
WOW_AUTOUPDATE=1; IDLE_SECS=180; STALL_SECS=150; PREWARM_MAX_SECS=1800
setidle() { echo $(( $(date +%s) - $1 )) > "$INPUT_STAMP"; }  # idle seconds == $1
run() { ACTIONS=""; autoupdate_tick "$1"; }                   # $1 = wow_up
has() { echo "$ACTIONS" | grep -q "$1"; }

# 1. disabled -> nothing
WOW_AUTOUPDATE=0; setidle 300; PR=1; US=1; UA=1; AGE=60; run 0
assert_eq "" "$ACTIONS" "disabled: no actions"
WOW_AUTOUPDATE=1

# 2. idle past threshold, no WoW, pre-warm not running -> launch
setidle 300; PR=1; US=1; UA=0; AGE=60; run 0
assert_eq " launch" "$ACTIONS" "idle + not running -> launch"

# 3. input returned (idle < threshold) while pre-warm running -> kill (yield prefix)
setidle 5; PR=0; US=1; UA=0; AGE=60; run 0
has kill && echo "  ok: input-return -> kill" || { echo "  FAIL: expected kill, got '$ACTIONS'"; exit 1; }

# 4. WoW running while pre-warm running -> kill
setidle 300; PR=0; US=1; UA=0; AGE=60; run 1
has kill && echo "  ok: wow-up -> kill" || { echo "  FAIL: expected kill, got '$ACTIONS'"; exit 1; }

# 5. stalled update, no WoW -> recover
setidle 5; PR=1; US=0; UA=0; AGE=60; run 0
has recover && echo "  ok: stalled -> recover" || { echo "  FAIL: expected recover, got '$ACTIONS'"; exit 1; }

# 6. pre-warm running, update finished (not active), age>120 -> kill (up to date)
setidle 300; PR=0; US=1; UA=1; AGE=200; run 0
has kill && echo "  ok: up-to-date -> kill" || { echo "  FAIL: expected kill, got '$ACTIONS'"; exit 1; }

# 7. pre-warm running, still downloading (active), idle, young -> NO kill, NO launch
setidle 300; PR=0; US=1; UA=0; AGE=60; run 0
has kill && { echo "  FAIL: unexpected kill while downloading"; exit 1; } || echo "  ok: downloading -> hold"
has launch && { echo "  FAIL: unexpected launch while already running"; exit 1; } || echo "  ok: no duplicate launch"

finish
