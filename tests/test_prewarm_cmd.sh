#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

PROTON_DIR=/opt/ge/GE-Proton11-12
SNIPER=/opt/slr/SteamLinuxRuntime_sniper/_v2-entry-point
BNET_EXE="/games/Battle.net/Battle.net Launcher.exe"
cmd=$(prewarm_cmd)
echo "$cmd" | grep -q -- "--backend headless"           && echo "  ok: headless" || { echo FAIL headless; exit 1; }
echo "$cmd" | grep -q -- "_v2-entry-point --verb=run"   && echo "  ok: sniper"   || { echo FAIL sniper; exit 1; }
echo "$cmd" | grep -q -- "/proton run"                  && echo "  ok: proton"   || { echo FAIL proton; exit 1; }
echo "$cmd" | grep -q -- "--autostarted"                && echo "  ok: autostart"|| { echo FAIL autostart; exit 1; }
finish
