#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
# Sourcing the watchdog must define functions WITHOUT starting the loop.
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh
assert_ok declare -F autoupdate_enabled >/dev/null
finish
