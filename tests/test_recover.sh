#!/bin/bash
# Layer C recovery: recover_stalled_update drives real process restarts, so we stub
# everything it touches (log/sleep/restart_bnet/update_active/update_stalled) to verify
# its control flow deterministically and instantly: recovers on completion, recovers on
# resumed progress, and is bounded to exactly UPDATE_RETRIES restarts before giving up.
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

log() { :; }
sleep() { :; }                 # no real waiting; the inner loop still advances `waited`
UPDATE_RETRIES=3
STALL_SECS=30                  # inner loop caps at STALL_SECS/10 = 3 iterations per retry
BNET_AGENT_LOGS=/none
restart_bnet() { RESTARTS=$((RESTARTS + 1)); }

# Case A: the update clears (no longer active) after the first restart -> recover, return 0.
RESTARTS=0
update_active() { return 1; }   # not active == completed/cleared
update_stalled() { return 0; }
recover_stalled_update; rc=$?
assert_eq 0 "$rc" "A: returns 0 when the update completes"
assert_eq 1 "$RESTARTS" "A: restarted exactly once"

# Case B: the update stays active AND stalled -> exhausts retries, returns 1 (bounded).
RESTARTS=0
update_active() { return 0; }   # always active
update_stalled() { return 0; }  # always stalled
recover_stalled_update; rc=$?
assert_eq 1 "$rc" "B: returns 1 after exhausting retries"
assert_eq 3 "$RESTARTS" "B: restarted exactly UPDATE_RETRIES times (bounded)"

# Case C: active but no longer stalled -> recover via resumed progress, return 0.
RESTARTS=0
update_active() { return 0; }
update_stalled() { return 1; }  # progressing again
recover_stalled_update; rc=$?
assert_eq 0 "$rc" "C: returns 0 when the download resumes progress"
assert_eq 1 "$RESTARTS" "C: restarted exactly once"

finish
