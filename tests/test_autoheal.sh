#!/bin/bash
# Auto-heal detection: spin_sample_stuck flags a CPU-spinning Agent that writes no bytes
# (the stuck-update signature) while NOT flagging a healthy install (writes) or an idle Agent.
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

# window 30s -> ">50% of a core" threshold is 50*30 = 1500 ticks.
assert_ok   spin_sample_stuck 2000 0 30      # spinning hard, zero writes -> stuck
assert_ok   spin_sample_stuck 1500 0 30      # exactly at the 50% threshold -> stuck
assert_fail spin_sample_stuck 2000 4096 30   # spinning BUT writing (healthy install) -> not stuck
assert_fail spin_sample_stuck 100 0 30       # almost no CPU (idle/settled) -> not stuck
assert_fail spin_sample_stuck 1499 0 30      # just under the busy threshold -> not stuck
assert_fail spin_sample_stuck 2000 0 0       # zero window -> not stuck (guard, no div-by-zero)
assert_fail spin_sample_stuck 2000 -5 30     # negative write delta (log rotated) -> not stuck

# stuck_addons: flags content packs (many files) but not normal addons (few files).
ad=$(mktemp -d); ADDONS_DIR="$ad"; ADDON_FILE_MAX=5
mkdir -p "$ad/BigPack/s"; for i in $(seq 1 10); do : > "$ad/BigPack/s/f$i"; done
mkdir -p "$ad/SmallAddon"; : > "$ad/SmallAddon/a"; : > "$ad/SmallAddon/b"
out=$(stuck_addons)
echo "$out" | grep -qx BigPack && echo "  ok: flags BigPack (over file threshold)" || { echo "  FAIL: BigPack not flagged ('$out')"; exit 1; }
echo "$out" | grep -qx SmallAddon && { echo "  FAIL: SmallAddon wrongly flagged"; exit 1; } || echo "  ok: spares SmallAddon (under threshold)"
finish
