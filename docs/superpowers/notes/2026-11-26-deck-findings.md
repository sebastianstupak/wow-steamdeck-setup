# On-Deck validation findings — WoW: Forever auto-update

**Date:** 2026-11-26 · **Deck:** SteamOS (neptune), user `deck`, GE-Proton 11-12, WoW: Forever.

Live validation over SSH. It confirmed the headless pre-warm works **and** corrected two
design assumptions that the off-Deck fixtures had encoded wrong.

## Confirmed environment values

| Thing | Value |
| --- | --- |
| Battle.net shortcut appid | `2153225858` |
| Proton build (config.vdf CompatToolMapping) | `GE-Proton11-12-x86_64` |
| Proton's required runtime (toolmanifest `require_tool_appid`) | **`4183110` → `SteamLinuxRuntime_4`** (python 3.13) |
| Sniper runtime (`1628350`) python | 3.9.2 — **too old** for GE-Proton 11 |
| `gamescope --backend headless` | works over SSH (own Xwayland on `:1`) |
| Readable input nodes | `event0-5,10,11` (gamepad/controller readable as `deck`) |
| WoW product code | `wowf` · flavor dir `_forever_` · Data dir ~52 GB |
| loginctl IdleHint | `no` (confirms we must use evdev, not logind) |

## Design corrections forced by the Deck (see commit 34fc76a)

1. **Runtime, not sniper.** The research-derived `_v2-entry-point` wrapper used
   `SteamLinuxRuntime_sniper`, whose python 3.9 makes GE-Proton 11-12's `proton` script
   die with `ImportError: cannot import name 'Self' from typing`. GE-Proton 11 requires
   `SteamLinuxRuntime_4`. Fix: `resolve_runtime_entry` derives the runtime from the Proton's
   `toolmanifest.vdf` `require_tool_appid` → that appid's `appmanifest_<id>.acf` `installdir`.

2. **Bytes, not log markers.** Battle.net logs `OP_UPDATE '...completed'` **only for product
   `'agent'`** (its own self-update), never for `'wowf'`; and the Operations-log mtime stayed
   frozen for ~70s while +341 MiB downloaded. So the log-marker `update_active`/`update_stalled`
   detection was unreliable. Replaced with **WoW Data-dir byte-growth sampling**
   (`wow_data_bytes` + `manage_prewarm`): downloading / finished (quiet after growth) /
   up-to-date (no growth) / kill on input|WoW|cap. Stall recovery is implicit (a fresh
   pre-warm each idle window resumes the partial download from disk).

3. **Cooldown.** Service-level test showed an up-to-date game + idle Deck would churn
   launch→"up to date"→close→relaunch. Added `COOLDOWN_SECS` (default 30 min).

4. **Log separation.** Proton/gamescope stdout (color codes, Xalia tracebacks) was polluting
   the main watchdog log → moved to `~/.local/state/wow-guard-prewarm.log`.

## What was observed working (production path)

- Manual launch of the exact `prewarm_cmd` (with SLR_4): Battle.net booted **headless**
  (`Battle.net.exe` + `Agent.exe`), invisible, no controller grab, and **downloaded
  +341 MiB** of a pending `wowf` update.
- `manage_prewarm` with idle < `IDLE_SECS` (simulating the user returning) **killed** a
  running pre-warm → **0** Battle.net/gamescope procs, stamp removed (prefix released).
- The **service itself** auto-launched a pre-warm once idle crossed the threshold and
  booted Battle.net headless (full production path, not a manual call).
- idle-watch.py runs under the service; `INPUT_STAMP` ages correctly.

## Not yet observed (incidental, not a gap)

- A full download→"finished, closing" cycle end-to-end: the game became **up to date**
  during testing, so there was nothing left to download. The "finished" and "up-to-date"
  branches are covered by `tests/test_tick.sh`; the download capability is proven above.
