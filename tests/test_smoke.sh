#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
# Sourcing the watchdog must define functions WITHOUT starting the loop.
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh
assert_ok declare -F autoupdate_enabled >/dev/null

for fn in update_active login_needed update_stalled recover_stalled_update \
          idle_seconds should_prewarm prewarm_cmd prewarm_launch prewarm_kill \
          start_idle_watch autoupdate_tick; do
  assert_ok declare -F "$fn" >/dev/null
done

finish
