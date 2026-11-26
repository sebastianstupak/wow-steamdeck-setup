#!/bin/bash
# Integration test for the pre-warm state machine (autoupdate_tick + manage_prewarm).
# Stubs every side-effecting helper (incl. wow_data_bytes) and records which actions fire,
# so the decisions are verified deterministically with no processes and no Deck.
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

ACTIONS=""
log() { :; }
start_idle_watch() { :; }
prewarm_launch() { ACTIONS="$ACTIONS launch"; }
prewarm_kill()   { ACTIONS="$ACTIONS kill"; }
prewarm_running() { return $PR; }          # 0 => running (true)
prewarm_age()     { echo "$AGE"; }
wow_data_bytes()  { echo "$BYTES"; }
IDLE_PID=fake
INPUT_STAMP=$(mktemp)
WOW_AUTOUPDATE=1; IDLE_SECS=180; SAMPLE_SECS=30; GROWTH_MIN=1048576
QUIET_SECS=150; UPTODATE_SECS=240; PREWARM_MAX_SECS=3600; COOLDOWN_SECS=1800; PW_LAST_END=0
setidle() { echo $(( $(date +%s) - $1 )) > "$INPUT_STAMP"; }   # idle seconds == $1

# ---- autoupdate_tick dispatch ----
WOW_AUTOUPDATE=0; setidle 300; PR=1; ACTIONS=""; autoupdate_tick 0
assert_eq "" "$ACTIONS" "disabled: no actions"
WOW_AUTOUPDATE=1

setidle 300; PR=1; AGE=0; BYTES=0; ACTIONS=""; autoupdate_tick 0          # idle, not running
assert_eq " launch" "$ACTIONS" "idle + not running -> launch"

setidle 5; PR=1; ACTIONS=""; autoupdate_tick 0                            # not idle
assert_eq "" "$ACTIONS" "not idle enough -> no launch"

setidle 300; PR=1; PW_LAST_END=$(date +%s); ACTIONS=""; autoupdate_tick 0  # within cooldown
assert_eq "" "$ACTIONS" "within cooldown -> no relaunch (don't churn when up to date)"
PW_LAST_END=0

setidle 300; PR=0; AGE=10; BYTES=100; PW_LAST_SAMPLE=$(date +%s); PW_SAW_GROWTH=0; PW_LAST_BYTES=100
ACTIONS=""; autoupdate_tick 0                                             # running -> manage_prewarm
assert_eq "" "$ACTIONS" "running, sample not due -> hold (manage, no launch)"

# ---- manage_prewarm decision matrix ----
mp() { ACTIONS=""; manage_prewarm "$1" "$2"; }   # $1 wow_up, $2 idle
AGE=100; mp 1 300;  assert_eq " kill" "$ACTIONS" "WoW running -> kill (yield prefix)"
AGE=100; mp 0 5;    assert_eq " kill" "$ACTIONS" "input returned -> kill"
AGE=9999; mp 0 300; assert_eq " kill" "$ACTIONS" "hard cap -> kill"

# growth detected this sample -> keep downloading, mark saw_growth
AGE=100; PW_LAST_SAMPLE=0; PW_LAST_BYTES=1000; BYTES=$((1000 + 2*1048576)); PW_SAW_GROWTH=0; PW_LAST_GROWTH=$(date +%s)
mp 0 300; assert_eq "" "$ACTIONS" "actively downloading -> hold"
assert_eq 1 "$PW_SAW_GROWTH" "growth sets saw_growth"

# had grown, now quiet for QUIET_SECS -> finished
AGE=400; PW_LAST_SAMPLE=0; PW_LAST_BYTES=5000; BYTES=5000; PW_SAW_GROWTH=1; PW_LAST_GROWTH=$(( $(date +%s) - QUIET_SECS - 5 ))
mp 0 300; assert_eq " kill" "$ACTIONS" "download finished (quiet after growth) -> kill"

# never grew, aged past UPTODATE_SECS -> already up to date
AGE=$((UPTODATE_SECS + 5)); PW_LAST_SAMPLE=0; PW_LAST_BYTES=5000; BYTES=5000; PW_SAW_GROWTH=0
mp 0 300; assert_eq " kill" "$ACTIONS" "no activity + aged -> up-to-date kill"

# never grew but still young (booting/logging in) -> hold
AGE=60; PW_LAST_SAMPLE=0; PW_LAST_BYTES=5000; BYTES=5000; PW_SAW_GROWTH=0
mp 0 300; assert_eq "" "$ACTIONS" "no activity but young -> hold"

finish
