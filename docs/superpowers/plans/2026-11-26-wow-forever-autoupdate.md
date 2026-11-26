# WoW: Forever Background Auto-Update — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep WoW: Forever's Battle.net update downloaded ahead of time and make the update itself never hang "forever," all inside the existing `wow-guard` watchdog.

**Architecture:** Three layers added to `wow-guard`. **(C) Reliability:** watch the Battle.net Agent's download and, if it stalls, tear down the stuck Agent/stack and retry — this runs during *any* update (Play or pre-warm). **(B) Triggers:** on wake, let an already-running Battle.net resume its auto-download (existing behavior); separately, during genuine awake-idle windows, run a pre-warm. **(A) Invisible launch:** the pre-warm launches the Battle.net prefix *manually* (bypassing Steam, so no controller grab) inside a nested `gamescope --backend headless` (no window), and is killed the instant input resumes so it releases the Proton prefix lock before you reach Play. A master toggle (`WOW_AUTOUPDATE`, default on) gates all new behavior.

**Tech Stack:** Bash (the watchdog), Python 3 (SteamOS-provided, for a tiny evdev idle reader), systemd `--user`, gamescope, Proton/Steam Linux Runtime (sniper), Battle.net Agent logs. Dev-side tests run in Git Bash on Windows.

## Global Constraints

- **Everything lives under `~/.local`** (watchdog in `~/.local/bin`, unit in `~/.config/systemd/user`, state in `~/.local/state`). Nothing outside it — must survive SteamOS updates. (Existing repo invariant.)
- **No system package installs** on the Deck. Use only what SteamOS already ships (bash, coreutils, `pgrep`/`pkill`, `python3`, `gamescope`, `busctl`, the Steam Linux Runtime).
- **Default ON:** `WOW_AUTOUPDATE` defaults to enabled (mimics Steam's "always keep updated" default). With `WOW_AUTOUPDATE=0`, behavior is **identical to today's watchdog**.
- **Honest physics:** a suspended Deck downloads nothing; a brand-new large patch still downloads at Play time. The win is reliability + pre-warm during awake windows.
- **Non-intrusive:** never fight the user. The headless pre-warm runs only during idle and is killed on any input, on imminent suspend, or when WoW starts. It must never grab the screen or controller.
- **One program per Proton prefix:** a pre-warm and a Play launch cannot run in the same prefix at once. "Reuse the in-flight update" = partial download bytes persist on disk; pre-warm yields the prefix, Play resumes the partial download.
- **Scriptable facts to confirm on-Deck** come from `docs/superpowers/notes/2026-11-26-deck-findings.md` (produced by Task 1). All marker/path constants in the code carry research-derived defaults and are confirmed/adjusted against that file.

---

## File Structure

- `wow-guard/wow-guard.sh` — **modify.** Refactor to be *sourceable* (wrap the main loop in `main()` guarded by `BASH_SOURCE`), add a top-of-file **CONFIG block** (paths, markers, tunables), and add the new functions (update-state detection, stall/retry, idle/pre-warm decision, headless launch + teardown). Responsibility: the whole watchdog.
- `wow-guard/idle-watch.py` — **create.** ~30-line evdev reader: watches readable `/dev/input/event*`, writes the current epoch to a stamp file on each input event (debounced). Responsibility: produce an "idle clock" the watchdog reads. Nothing else.
- `wow-guard/wow-guard.service` — **modify.** Add `Environment=WOW_AUTOUPDATE=1` (and commented tunables). Responsibility: unit definition + default toggle.
- `wow-guard/install.sh` — **modify.** Also install `idle-watch.py`; keep the `bash -n` syntax check. Responsibility: on-Deck installer.
- `setup.sh` — **modify.** Add `idle-watch.py` to the `scp` list. Responsibility: remote one-command install.
- `tests/assert.sh` — **create.** Tiny assert helpers for bash tests.
- `tests/run.sh` — **create.** Runs all `tests/test_*.sh`, prints pass/fail, non-zero exit on failure.
- `tests/test_*.sh` — **create** (several). Unit tests for the pure-logic functions, using fixtures.
- `tests/fixtures/` — **create.** Sample Agent/launcher log files for detection tests.
- `README.md` — **modify.** New "Auto-update / pre-warm" section incl. the one-time Battle.net settings and the toggle.
- `docs/superpowers/notes/2026-11-26-deck-findings.md` — **create** (Task 1). The on-Deck confirmation record.

**Constant names used across tasks (define once in the CONFIG block, Task 2):**
- `PFX` — existing: `$HOME/.local/share/Steam/steamapps/compatdata/$APPID/pfx/drive_c`
- `BNET_LAUNCHER_LOGS="$PFX/users/steamuser/AppData/Local/Battle.net/Logs"` (note: `users/steamuser`, matching the existing `BNET_LOGS`)
- `BNET_AGENT_LOGS="$PFX/ProgramData/Battle.net/Agent"` (Operations-*.log / Agent-*.log live under here and `Agent.<build>/Logs/`)
- `WOW_AUTOUPDATE` (default `1`), `IDLE_SECS` (default `180`), `STALL_SECS` (default `150`), `UPDATE_RETRIES` (default `3`), `PREWARM_MAX_SECS` (default `1800`)
- `INPUT_STAMP="$HOME/.local/state/wow-guard.input"`

**Function signatures used across tasks (consistent names):**
- `autoupdate_enabled` → exit 0 if enabled.
- `update_active <agent_logs_dir>` → exit 0 if an update is in progress.
- `update_stalled <agent_logs_dir> <stall_secs>` → exit 0 if in progress **and** frozen.
- `login_needed <launcher_logs_dir>` → exit 0 if a saved session expired and needs a human.
- `idle_seconds <stamp_file>` → echoes integer seconds since last input (large number if unknown).
- `should_prewarm <enabled> <wow_running> <idle_secs> <idle_threshold>` → exit 0 if a pre-warm should start.
- `prewarm_launch` / `prewarm_kill` → start/stop the headless background launcher (Task 7).

---

## Task 1: On-Deck environment spike (confirm the unknowns)

**Files:**
- Create: `docs/superpowers/notes/2026-11-26-deck-findings.md`

**Interfaces:**
- Produces: confirmed values the later tasks' CONFIG block is checked against — Agent-log path + a real `OP_UPDATE` line, the shortcut's Proton build name, the sniper entry-point path, a readable input `event*` node, and that `gamescope --backend headless` runs.

This task is **run on the Steam Deck** (over SSH or in Desktop Mode). No code changes; the deliverable is the filled-in findings file. Each step is a command whose output you paste into the file.

- [ ] **Step 1: Record the Battle.net appid and prefix**

Run on the Deck:
```bash
for d in "$HOME/.local/share/Steam/steamapps/compatdata"/*/; do
  [ -e "$d/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe" ] && echo "APPID=$(basename "$d")"
done
```
Expected: one `APPID=<number>` line. Record it.

- [ ] **Step 2: Confirm Agent + launcher log locations and a real update marker**

Run (substitute `<APPID>`):
```bash
P="$HOME/.local/share/Steam/steamapps/compatdata/<APPID>/pfx/drive_c"
ls -t "$P/ProgramData/Battle.net/Agent/"*/Logs/Operations-*.log 2>/dev/null | head -3
ls -t "$P/ProgramData/Battle.net/Agent/Logs/"Operations-*.log 2>/dev/null | head -3
ls -t "$P/users/steamuser/AppData/Local/Battle.net/Logs/"battle.net-*.log | head -3
grep -ah "OP_UPDATE for" "$P/ProgramData/Battle.net/Agent/"*/Logs/Operations-*.log 2>/dev/null | tail -5
grep -ah -e "Logged into Battle.net successfully" -e "SSO Token generation error" \
  "$P/users/steamuser/AppData/Local/Battle.net/Logs/"battle.net-*.log 2>/dev/null | tail -5
```
Expected: real file paths and at least one `OP_UPDATE for '...'` line (trigger a WoW update first if none exist). **Record the exact directory that actually contains `Operations-*.log`** — the CONFIG block's `BNET_AGENT_LOGS` must point at it.

- [ ] **Step 3: Resolve the shortcut's Proton build, sniper path, and GE-Proton dir**

Run:
```bash
grep -A3 "\"<APPID>\"" "$HOME/.local/share/Steam/config/config.vdf" | grep -i name
ls -d "$HOME/.local/share/Steam/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point"
ls -d "$HOME/.local/share/Steam/compatibilitytools.d/"*/proton 2>/dev/null
```
Expected: the Proton build `name` (e.g. `GE-Proton11-12`), the sniper entry-point path exists, and the matching `proton` script path. Record all three.

- [ ] **Step 4: Confirm headless gamescope and a readable input node**

Run:
```bash
gamescope --help 2>&1 | grep -i backend         # confirm "headless" is listed
gamescope --backend headless -W 640 -H 480 -- sleep 2 && echo "HEADLESS_OK"
grep -B2 -A4 -iE "controller|x-box|xbox|keyboard" /proc/bus/input/devices | grep -i handlers
for e in /dev/input/event*; do [ -r "$e" ] && echo "readable: $e"; done
```
Expected: `headless` appears in help, `HEADLESS_OK` prints, and at least one `readable: /dev/input/eventN` (a gamepad/controller/keyboard node). Record which nodes are readable.

- [ ] **Step 5: Confirm the resume + input signals behave as researched**

Run:
```bash
sid=$(loginctl list-sessions --no-legend | awk 'NR==1{print $1}')
loginctl show-session "$sid" -p IdleHint -p IdleSinceHint     # expect IdleHint=no (so we DON'T use it)
busctl --system --timeout=3 monitor --match "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" || true
```
Expected: `IdleHint=no` (confirms we must use evdev, not logind). Note it in the file.

- [ ] **Step 6: Set the one-time Battle.net settings and record done**

In the Battle.net launcher (Desktop Mode), set and record as done in the file:
- Settings → **Game Install/Update → Automatic Updates: ON**.
- Settings → **App**: "When I close Battle.net" → **Minimize to system tray**; **Launch minimized to system tray: ON**.
- Settings → **Downloads → Limit download bandwidth = 0** (uncapped).
- Login: **Keep me logged in** checked; confirm the launcher auto-signs-in on a fresh launch.

- [ ] **Step 7: Commit the findings**

```bash
git add docs/superpowers/notes/2026-11-26-deck-findings.md
git commit -m "docs: on-Deck findings for wow-guard auto-update spike"
```

---

## Task 2: Make wow-guard.sh sourceable + add the CONFIG block + test harness

**Files:**
- Modify: `wow-guard/wow-guard.sh` (wrap main loop in `main()`; add CONFIG block)
- Create: `tests/assert.sh`, `tests/run.sh`
- Test: `tests/test_smoke.sh`

**Interfaces:**
- Produces: a sourceable `wow-guard.sh` (sourcing it defines the functions but does **not** run the loop), the CONFIG constants listed above, and `tests/run.sh` as the test entry point.

- [ ] **Step 1: Write the failing smoke test**

Create `tests/assert.sh`:
```bash
#!/bin/bash
# Minimal assert helpers for wow-guard tests.
_fails=0
assert_eq() { # $1 expected $2 actual $3 msg
  if [ "$1" = "$2" ]; then echo "  ok: $3"; else echo "  FAIL: $3 (expected '$1', got '$2')"; _fails=$((_fails+1)); fi
}
assert_ok() { # runs "$@"; passes if exit 0
  if "$@"; then echo "  ok: $* -> 0"; else echo "  FAIL: $* -> $?"; _fails=$((_fails+1)); fi
}
assert_fail() { # runs "$@"; passes if non-zero
  if "$@"; then echo "  FAIL: $* -> 0 (wanted non-zero)"; _fails=$((_fails+1)); else echo "  ok: $* -> non-zero"; fi
}
finish() { [ "$_fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$_fails FAILED"; exit 1; }; }
```

Create `tests/run.sh`:
```bash
#!/bin/bash
# Run every tests/test_*.sh; non-zero exit if any fails.
cd "$(dirname "$0")" || exit 2
rc=0
for t in test_*.sh; do
  echo "== $t =="
  bash "$t" || rc=1
done
exit $rc
```

Create `tests/test_smoke.sh`:
```bash
#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
# Sourcing the watchdog must define functions WITHOUT starting the loop.
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh
assert_ok declare -F autoupdate_enabled >/dev/null
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — sourcing current `wow-guard.sh` runs the infinite `while` loop (hangs) or `autoupdate_enabled` is undefined.

- [ ] **Step 3: Refactor wow-guard.sh to be sourceable + add CONFIG**

In `wow-guard/wow-guard.sh`, after the existing `find_appid`/`APPID` resolution and path setup, add the CONFIG block (new constants) near the other path vars:
```bash
# ---- auto-update config (Task 2) -------------------------------------------
BNET_LAUNCHER_LOGS="$PFX/users/steamuser/AppData/Local/Battle.net/Logs"
BNET_AGENT_LOGS="$PFX/ProgramData/Battle.net/Agent"   # confirm exact Logs subdir on-Deck
WOW_AUTOUPDATE="${WOW_AUTOUPDATE:-1}"
IDLE_SECS="${IDLE_SECS:-180}"
STALL_SECS="${STALL_SECS:-150}"
UPDATE_RETRIES="${UPDATE_RETRIES:-3}"
PREWARM_MAX_SECS="${PREWARM_MAX_SECS:-1800}"
INPUT_STAMP="$HOME/.local/state/wow-guard.input"
```
Then wrap the existing main loop. Replace the current top-level `declare -A seen … while sleep 1; do … done` with a `main()` function containing exactly that code, and guard execution at the very end of the file:
```bash
main() {
    declare -A seen
    for p in $(pgrep -x Wow.exe); do seen[$p]=1; done
    log "started (appid $APPID; existing WoW: ${!seen[*]})"
    last=$(date +%s)
    while sleep 1; do
        # ... existing loop body unchanged ...
    done
}

# Run the loop only when executed directly, never when sourced for tests.
if [ -z "${SOURCING_FOR_TEST:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
```
Also guard the appid resolution so sourcing a dev machine (no Deck prefix) doesn't `exit 1`: when `SOURCING_FOR_TEST` is set, skip the `find_appid || exit` block and set `APPID=TEST PFX=/tmp/none` placeholders.

- [ ] **Step 4: Add the first new function so the smoke test can pass**

Add near the other functions:
```bash
# Is background auto-update enabled? (default on; WOW_AUTOUPDATE=0 disables all new behavior)
autoupdate_enabled() { [ "${WOW_AUTOUPDATE:-1}" != "0" ]; }
```

- [ ] **Step 5: Run the smoke test to verify it passes**

Run: `bash tests/run.sh`
Expected: `ok: declare -F autoupdate_enabled` and `ALL PASS`. It must return promptly (no hang — proving the loop doesn't run on source).

- [ ] **Step 6: Verify the script still parses and the installer's check still holds**

Run: `bash -n wow-guard/wow-guard.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 7: Commit**

```bash
git add wow-guard/wow-guard.sh tests/assert.sh tests/run.sh tests/test_smoke.sh
git commit -m "refactor(wow-guard): sourceable main() + config block + test harness"
```

---

## Task 3: Toggle gating (`autoupdate_enabled`) + service env + unit test

**Files:**
- Modify: `wow-guard/wow-guard.service`
- Test: `tests/test_toggle.sh`

**Interfaces:**
- Consumes: `autoupdate_enabled` (Task 2).
- Produces: the unit ships the default-on toggle; confirmed behavior for on/off/unset.

- [ ] **Step 1: Write the failing test**

Create `tests/test_toggle.sh`:
```bash
#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh
WOW_AUTOUPDATE=1 ; assert_ok   autoupdate_enabled
WOW_AUTOUPDATE=0 ; assert_fail autoupdate_enabled
unset WOW_AUTOUPDATE ; assert_ok autoupdate_enabled   # default ON
finish
```

- [ ] **Step 2: Run to verify current state**

Run: `bash tests/test_toggle.sh`
Expected: PASS already (the function exists from Task 2). If the unset case fails, fix `autoupdate_enabled` to use `${WOW_AUTOUPDATE:-1}` (it already does) — this test locks the default-on contract.

- [ ] **Step 3: Add the toggle to the service unit**

Edit `wow-guard/wow-guard.service`, add under `[Service]` above `ExecStart`:
```ini
# Background auto-update of WoW: Forever. Set to 0 to disable all pre-warm/update behavior.
Environment=WOW_AUTOUPDATE=1
# Optional tuning (uncomment to override): Environment=IDLE_SECS=180 STALL_SECS=150 UPDATE_RETRIES=3
```

- [ ] **Step 4: Verify the unit still parses**

Run: `grep -c '^Environment=WOW_AUTOUPDATE=1' wow-guard/wow-guard.service`
Expected: `1`.

- [ ] **Step 5: Commit**

```bash
git add wow-guard/wow-guard.service tests/test_toggle.sh
git commit -m "feat(wow-guard): WOW_AUTOUPDATE toggle (default on) in the unit"
```

---

## Task 4: Update-state detection (`update_active`, `login_needed`) + tests

**Files:**
- Modify: `wow-guard/wow-guard.sh`
- Create: `tests/fixtures/agent/Operations-active.log`, `tests/fixtures/agent/Operations-done.log`, `tests/fixtures/launcher/battle.net-expired.log`, `tests/fixtures/launcher/battle.net-ok.log`
- Test: `tests/test_detection.sh`

**Interfaces:**
- Produces: `update_active <agent_logs_dir>` and `login_needed <launcher_logs_dir>`, consumed by Tasks 5, 7, 8.

- [ ] **Step 1: Create fixtures**

`tests/fixtures/agent/Operations-active.log`:
```
I [InstallManager]   Queue operation - OP_UPDATE for 'wow'
I [tact]             Starting build-update: 20 | Base: 0000
I [tact]             Priority[0] | C-Files: 0 | L-Files: 6 | O-Files: 0 | Patch: 0
```
`tests/fixtures/agent/Operations-done.log`:
```
I [InstallManager]   Queue operation - OP_UPDATE for 'wow'
I [InstallManager]   OP_UPDATE for 'wow' completed
```
`tests/fixtures/launcher/battle.net-expired.log`:
```
I [BNLogin]          Connecting...
W [InstallManager]   Your login session has expired. (BLZBNTBGS80000023)
```
`tests/fixtures/launcher/battle.net-ok.log`:
```
W [InstallManager]   Your login session has expired. (BLZBNTBGS80000023)
I [BNLogin]          Logged into Battle.net successfully.
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_detection.sh`:
```bash
#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

# update_active: file whose last OP_UPDATE has no "completed" -> active
ad=$(mktemp -d)
cp fixtures/agent/Operations-active.log "$ad/Operations-1.log"
assert_ok update_active "$ad"
cp fixtures/agent/Operations-done.log "$ad/Operations-2.log"   # newer, completed
touch -d "+1 sec" "$ad/Operations-2.log" 2>/dev/null || sleep 1
assert_fail update_active "$ad"
assert_fail update_active /nonexistent

# login_needed: expired with NO later success -> needs login; expired THEN success -> fine
ld=$(mktemp -d)
cp fixtures/launcher/battle.net-expired.log "$ld/battle.net-1.log"
assert_ok login_needed "$ld"
cp fixtures/launcher/battle.net-ok.log "$ld/battle.net-1.log"
assert_fail login_needed "$ld"
finish
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/test_detection.sh`
Expected: FAIL — `update_active`/`login_needed` not defined.

- [ ] **Step 4: Implement the functions**

Add to `wow-guard/wow-guard.sh` near the other helpers:
```bash
# An update is "active" when the newest Operations log's last OP_UPDATE line has no
# matching "completed". (Agent markers confirmed in the on-Deck findings.)
update_active() { # $1 = agent logs dir (searched recursively for Operations-*.log)
    local f
    f=$(ls -t "$1"/Operations-*.log "$1"/*/Logs/Operations-*.log 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    local last; last=$(grep -a 'OP_UPDATE for' "$f" | tail -1)
    [ -n "$last" ] || return 1
    case "$last" in *completed*) return 1 ;; *) return 0 ;; esac
}

# The saved session expired and needs a human: the expired marker appears with no
# later "Logged into Battle.net successfully." in the newest launcher log.
login_needed() { # $1 = launcher logs dir
    local f; f=$(ls -t "$1"/battle.net-*.log 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    local exp ok
    exp=$(grep -an -e 'Your login session has expired' -e 'BLZBNTBGS80000023' "$f" | tail -1 | cut -d: -f1)
    [ -n "$exp" ] || return 1
    ok=$(grep -an 'Logged into Battle.net successfully' "$f" | tail -1 | cut -d: -f1)
    [ -z "$ok" ] || [ "$exp" -gt "$ok" ]   # expired is the most recent of the two
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test_detection.sh`
Expected: all `ok:` lines and `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add wow-guard/wow-guard.sh tests/fixtures tests/test_detection.sh
git commit -m "feat(wow-guard): detect active update + login-expired from Battle.net logs"
```

---

## Task 5: Stall detection + bounded retry (Layer C) + tests

**Files:**
- Modify: `wow-guard/wow-guard.sh`
- Test: `tests/test_stall.sh`

**Interfaces:**
- Consumes: `update_active` (Task 4), existing `kill_bnet_stack`/`restart_bnet`/`wait_network`.
- Produces: `update_stalled <agent_logs_dir> <stall_secs>` and `recover_stalled_update` (bounded retry), consumed by the main loop (Task 8).

- [ ] **Step 1: Write the failing test**

Create `tests/test_stall.sh`:
```bash
#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

ad=$(mktemp -d)
cp fixtures/agent/Operations-active.log "$ad/Operations-1.log"
# Fresh mtime -> active but NOT stalled
assert_fail update_stalled "$ad" 150
# Old mtime -> active AND frozen -> stalled
touch -d "400 seconds ago" "$ad/Operations-1.log"
assert_ok update_stalled "$ad" 150
# Not active (completed) -> never stalled even if old
cp fixtures/agent/Operations-done.log "$ad/Operations-1.log"
touch -d "400 seconds ago" "$ad/Operations-1.log"
assert_fail update_stalled "$ad" 150
finish
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_stall.sh`
Expected: FAIL — `update_stalled` undefined.

- [ ] **Step 3: Implement stall detection + recovery**

Add to `wow-guard/wow-guard.sh`:
```bash
# Stalled = an update is active AND the newest Agent log has not been written to for
# $2 seconds (download frozen). Uses log mtime as the no-progress signal.
update_stalled() { # $1 = agent logs dir, $2 = stall seconds
    update_active "$1" || return 1
    local f mt now
    f=$(ls -t "$1"/Operations-*.log "$1"/*/Logs/Operations-*.log "$1"/Agent-*.log "$1"/*/Logs/Agent-*.log 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    mt=$(stat -c %Y "$f" 2>/dev/null) || return 1
    now=$(date +%s)
    [ $((now - mt)) -ge "$2" ]
}

# Bounded recovery for a frozen update: tear the stack down and let it resume (Battle.net
# resumes a partial download on relaunch). Returns after UPDATE_RETRIES attempts.
recover_stalled_update() {
    local try
    for try in $(seq 1 "$UPDATE_RETRIES"); do
        log "update stalled (try $try/$UPDATE_RETRIES) - restarting Battle.net stack"
        restart_bnet "stalled update"
        # give the Agent time to re-queue and start writing again
        local waited=0
        while [ "$waited" -lt "$STALL_SECS" ]; do
            sleep 10; waited=$((waited + 10))
            update_active "$BNET_AGENT_LOGS" || { log "update finished/cleared after recovery"; return 0; }
            update_stalled "$BNET_AGENT_LOGS" "$STALL_SECS" || { log "update progressing again"; return 0; }
        done
    done
    log "update still stalled after $UPDATE_RETRIES tries - start it manually from Battle.net"
    return 1
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_stall.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: Verify syntax**

Run: `bash -n wow-guard/wow-guard.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`.

- [ ] **Step 6: Commit**

```bash
git add wow-guard/wow-guard.sh tests/test_stall.sh
git commit -m "feat(wow-guard): detect stalled update and recover with bounded retries (Layer C)"
```

---

## Task 6: Idle reader (`idle-watch.py`) + `idle_seconds` + `should_prewarm` + tests

**Files:**
- Create: `wow-guard/idle-watch.py`
- Modify: `wow-guard/wow-guard.sh`
- Test: `tests/test_idle.sh`

**Interfaces:**
- Produces: `idle-watch.py` (writes epoch to `INPUT_STAMP` on each input event), `idle_seconds <stamp_file>`, and `should_prewarm <enabled> <wow_running> <idle_secs> <idle_threshold>` — consumed by the main loop (Task 8) and the launch task (Task 7).

- [ ] **Step 1: Write `idle-watch.py`**

Create `wow-guard/idle-watch.py`:
```python
#!/usr/bin/env python3
# Writes the current epoch to a stamp file whenever a readable /dev/input/event*
# device reports activity. The watchdog reads the stamp to compute idle seconds.
# SteamOS ships python3; no pip packages required. Touchscreen nodes are not
# readable as the deck user and are simply skipped (a known gap).
import glob, os, select, struct, sys, time

STAMP = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.local/state/wow-guard.input")
EVENT_SIZE = struct.calcsize("llHHI")  # input_event on a 64-bit kernel

def open_readable():
    fds = []
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            fds.append(os.open(path, os.O_RDONLY | os.O_NONBLOCK))
        except OSError:
            pass  # touchscreen / permission-denied nodes
    return fds

def stamp():
    tmp = STAMP + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(int(time.time())))
    os.replace(tmp, STAMP)

def main():
    os.makedirs(os.path.dirname(STAMP), exist_ok=True)
    stamp()  # seed: treat startup as "just active"
    fds = open_readable()
    if not fds:
        # No readable input devices -> cannot provide an idle clock. Exit non-zero
        # so the watchdog disables the awake-idle layer and falls back to wake-only.
        sys.stderr.write("idle-watch: no readable /dev/input/event* devices\n")
        sys.exit(3)
    last = 0.0
    while True:
        r, _, _ = select.select(fds, [], [], 60)
        for fd in r:
            try:
                while os.read(fd, EVENT_SIZE):
                    pass  # drain
            except OSError:
                pass
        now = time.time()
        if r and now - last >= 1.0:  # debounce to ~1 write/sec
            stamp(); last = now

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_idle.sh`:
```bash
#!/bin/bash
cd "$(dirname "$0")" || exit 2
. ./assert.sh
SOURCING_FOR_TEST=1 . ../wow-guard/wow-guard.sh

sf=$(mktemp)
date +%s > "$sf"
# fresh stamp -> ~0 idle seconds
v=$(idle_seconds "$sf"); [ "$v" -le 2 ] && echo "  ok: fresh idle=$v" || { echo "  FAIL: fresh idle=$v"; exit 1; }
# stamp 300s ago -> ~300 idle seconds
echo $(( $(date +%s) - 300 )) > "$sf"
v=$(idle_seconds "$sf"); [ "$v" -ge 290 ] && [ "$v" -le 310 ] && echo "  ok: old idle=$v" || { echo "  FAIL: old idle=$v"; exit 1; }
# missing stamp -> large number (unknown == not idle)
v=$(idle_seconds /nonexistent); [ "$v" -ge 999999 ] && echo "  ok: missing idle=$v" || { echo "  FAIL: missing idle=$v"; exit 1; }

# should_prewarm: enabled, no WoW, idle past threshold -> yes
assert_ok   should_prewarm 1 0 200 180
assert_fail should_prewarm 0 0 200 180   # disabled
assert_fail should_prewarm 1 1 200 180   # WoW running
assert_fail should_prewarm 1 0 100 180   # not idle long enough
finish
```

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/test_idle.sh`
Expected: FAIL — `idle_seconds`/`should_prewarm` undefined.

- [ ] **Step 4: Implement the bash helpers**

Add to `wow-guard/wow-guard.sh`:
```bash
# Seconds since the last input event, from the stamp idle-watch.py maintains.
# Unknown/missing stamp -> a large number (so "idle" is never falsely assumed).
idle_seconds() { # $1 = stamp file
    local s now
    s=$(cat "$1" 2>/dev/null) || { echo 1000000; return; }
    case "$s" in ''|*[!0-9]*) echo 1000000; return ;; esac
    now=$(date +%s); echo $(( now - s ))
}

# Should a background pre-warm start now?
should_prewarm() { # $1 enabled(1/0) $2 wow_running(1/0) $3 idle_secs $4 idle_threshold
    [ "$1" = "1" ] || return 1
    [ "$2" = "0" ] || return 1
    [ "$3" -ge "$4" ] 2>/dev/null
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/test_idle.sh`
Expected: `ALL PASS`.

- [ ] **Step 6: Syntax-check both scripts**

Run: `bash -n wow-guard/wow-guard.sh && python3 -m py_compile wow-guard/idle-watch.py && echo OK`
Expected: `OK`. (On the Windows dev box, if `python3` is absent, run `py -3 -m py_compile ...`; the on-Deck install uses `python3`.)

- [ ] **Step 7: Commit**

```bash
git add wow-guard/idle-watch.py wow-guard/wow-guard.sh tests/test_idle.sh
git commit -m "feat(wow-guard): evdev idle reader + idle_seconds/should_prewarm"
```

---

## Task 7: Headless pre-warm launch + teardown (Layer A)

**Files:**
- Modify: `wow-guard/wow-guard.sh`
- Test: `tests/test_prewarm_cmd.sh`

**Interfaces:**
- Consumes: `APPID`, `PFX`, existing `kill_bnet_stack`.
- Produces: `prewarm_cmd` (pure string builder, unit-tested), `prewarm_launch`/`prewarm_kill` (side-effecting, validated on-Deck), and `prewarm_running` (exit 0 if a pre-warm instance is up). Consumed by the main loop (Task 8).

The launch bypasses Steam (so no Steam Input controller grab) and renders into a nested headless gamescope (no window). It must be killed on any input / imminent suspend / WoW start to release the Proton prefix lock before Play.

- [ ] **Step 1: Write the failing test for the command builder**

Create `tests/test_prewarm_cmd.sh`:
```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_prewarm_cmd.sh`
Expected: FAIL — `prewarm_cmd` undefined.

- [ ] **Step 3: Implement the launch/teardown functions**

Add to `wow-guard/wow-guard.sh`. Resolve the Proton build from `config.vdf` once, with env overrides for testing:
```bash
STEAM="$HOME/.local/share/Steam"
# Resolve the shortcut's Proton build name from CompatToolMapping, then its proton script.
resolve_proton_dir() {
    [ -n "$PROTON_DIR" ] && { echo "$PROTON_DIR"; return; }
    local name
    name=$(grep -A3 "\"$APPID\"" "$STEAM/config/config.vdf" 2>/dev/null | sed -n 's/.*"name"[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$name" ] && [ -d "$STEAM/compatibilitytools.d/$name" ] && { echo "$STEAM/compatibilitytools.d/$name"; return; }
    ls -d "$STEAM/compatibilitytools.d/"*/ 2>/dev/null | head -1 | sed 's#/$##'   # fallback: first GE build
}
SNIPER="${SNIPER:-$STEAM/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point}"
BNET_EXE="${BNET_EXE:-$PFX/Program Files (x86)/Battle.net/Battle.net Launcher.exe}"
PREWARM_MARK='gamescope --backend headless'          # unique enough to find/kill the pre-warm
PREWARM_STAMP="$HOME/.local/state/wow-guard.prewarm"  # launch time, for age/cap

# Build the off-screen launch command (printed so it is unit-testable without launching).
prewarm_cmd() {
    local proton; proton=$(resolve_proton_dir)
    printf '%s' "gamescope --backend headless -W 1280 -H 720 -- env " \
        "STEAM_COMPAT_DATA_PATH=$STEAM/steamapps/compatdata/$APPID " \
        "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM " \
        "'$SNIPER' --verb=run -- '$proton/proton' run '$BNET_EXE' --autostarted"
}

# Stateless detection/teardown by process marker (setsid's $! is unreliable; a marker
# also survives a watchdog restart). Teardown reuses the existing kill_bnet_stack.
prewarm_running() { pgrep -f "$PREWARM_MARK" >/dev/null 2>&1; }
prewarm_age() { local s; s=$(cat "$PREWARM_STAMP" 2>/dev/null) || { echo 0; return; }
    case "$s" in ''|*[!0-9]*) echo 0; return ;; esac; echo $(( $(date +%s) - s )); }

prewarm_launch() {
    prewarm_running && return 0
    login_needed "$BNET_LAUNCHER_LOGS" && { log "pre-warm skipped: Battle.net login expired - sign in once"; return 1; }
    bnet_running && { log "pre-warm skipped: Battle.net already running"; return 1; }
    log "pre-warm: launching Battle.net off-screen to update"
    nohup bash -c "$(prewarm_cmd)" >>"$LOG" 2>&1 &
    date +%s > "$PREWARM_STAMP"
}

prewarm_kill() {
    prewarm_running || { rm -f "$PREWARM_STAMP"; return 0; }
    log "pre-warm: tearing down off-screen Battle.net (releasing prefix)"
    pkill -TERM -f "$PREWARM_MARK" 2>/dev/null
    sleep 2
    kill_bnet_stack
    rm -f "$PREWARM_STAMP"
}
```

- [ ] **Step 4: Run to verify the builder test passes**

Run: `bash tests/test_prewarm_cmd.sh`
Expected: `ALL PASS`.

- [ ] **Step 5: On-Deck validation of the real launch (manual)**

On the Deck, with the service stopped (`systemctl --user stop wow-guard`), source and dry-run:
```bash
APPID=<APPID> ; STEAM="$HOME/.local/share/Steam"
PFX="$STEAM/steamapps/compatdata/$APPID/pfx/drive_c"
SOURCING_FOR_TEST=1 . ~/.local/bin/wow-guard.sh   # after Task 9 installs it, or source the repo copy
echo "CMD: $(prewarm_cmd)"            # eyeball it against the findings file
prewarm_launch ; sleep 60
ls -lt "$PFX/ProgramData/Battle.net/Agent/"*/Logs/Operations-*.log | head -1   # mtime should advance if updating
prewarm_running && echo "still running"
prewarm_kill ; prewarm_running && echo "BUG: still up" || echo "torn down OK"
```
Expected: the off-screen launch starts **without** any window appearing or the controller being grabbed; if an update is pending, the Agent Operations log mtime advances; `prewarm_kill` leaves nothing running. **Record the result in the findings file.** If headless launch fails here, note it — Task 8 keeps the pre-warm layer behind `autoupdate_enabled` so the rest (Layer C) still ships.

- [ ] **Step 6: Commit**

```bash
git add wow-guard/wow-guard.sh tests/test_prewarm_cmd.sh
git commit -m "feat(wow-guard): off-screen headless pre-warm launch + teardown (Layer A)"
```

---

## Task 8: Wire the layers into the main loop

**Files:**
- Modify: `wow-guard/wow-guard.sh` (`main()`)
- Test: `tests/test_smoke.sh` (extend to assert new funcs exist)

**Interfaces:**
- Consumes: everything from Tasks 2–7.
- Produces: the integrated watchdog behavior.

- [ ] **Step 1: Start + supervise the idle reader inside `main()`**

At the top of `main()` (after the existing `seen` setup), add:
```bash
IDLE_PID=""
start_idle_watch() {
    autoupdate_enabled || return 0
    [ -n "$IDLE_PID" ] && kill -0 "$IDLE_PID" 2>/dev/null && return 0
    python3 "$HOME/.local/bin/idle-watch.py" "$INPUT_STAMP" >>"$LOG" 2>&1 &
    IDLE_PID=$!
    sleep 1
    kill -0 "$IDLE_PID" 2>/dev/null || { IDLE_PID=""; log "idle-watch unavailable - awake-idle pre-warm disabled (wake handling unaffected)"; }
}
start_idle_watch
```

- [ ] **Step 2: Add the per-second Layer C + pre-warm logic in the loop**

Inside the `while sleep 1; do ... done`, after the existing duplicate-WoW / token blocks, add:
```bash
    if autoupdate_enabled; then
        wow_up=0; pgrep -x Wow.exe >/dev/null && wow_up=1

        # Layer C: recover a stalled update whenever one is in progress (Play or pre-warm).
        if [ "$wow_up" = 0 ] && update_stalled "$BNET_AGENT_LOGS" "$STALL_SECS"; then
            recover_stalled_update
        fi

        # Keep the idle reader alive.
        start_idle_watch

        # Headless pre-warm: only during a genuine idle window, never with WoW up.
        idle=$(idle_seconds "$INPUT_STAMP")
        if [ -n "$IDLE_PID" ] && should_prewarm 1 "$wow_up" "$idle" "$IDLE_SECS"; then
            prewarm_running || prewarm_launch
        fi

        # Yield the prefix the instant the user is back (input) or WoW starts, when the
        # download is done, or after a hard cap -> so a subsequent Play can resume the
        # partial download (prefix lock allows only one program at a time).
        if prewarm_running; then
            if [ "$wow_up" = 1 ] || [ "$idle" -lt "$IDLE_SECS" ] || [ "$(prewarm_age)" -ge "$PREWARM_MAX_SECS" ]; then
                prewarm_kill
            elif ! update_active "$BNET_AGENT_LOGS" && [ "$(prewarm_age)" -ge 120 ]; then
                log "pre-warm: nothing left to download (up to date) - closing"
                prewarm_kill
            fi
        fi
    fi
```
Note: the existing wake-from-sleep block (`gap > RESUME_MIN`) is unchanged — on wake, an already-running Battle.net resumes its own auto-download; we do **not** start a headless pre-warm on wake (prefix-lock + fast-grab). Add one line in that block so a stale pre-warm from before sleep is cleared: `prewarm_running && prewarm_kill` right after `log "Deck woke up..."`.

- [ ] **Step 3: Clean up children on exit**

Near the top of `main()` add a trap so the service stop/restart doesn't leak the idle reader or a pre-warm:
```bash
cleanup() { prewarm_kill 2>/dev/null; [ -n "$IDLE_PID" ] && kill "$IDLE_PID" 2>/dev/null; }
trap cleanup EXIT TERM INT
```

- [ ] **Step 4: Extend the smoke test**

Append to `tests/test_smoke.sh` before `finish`:
```bash
for fn in update_active login_needed update_stalled recover_stalled_update \
          idle_seconds should_prewarm prewarm_cmd prewarm_launch prewarm_kill; do
  assert_ok declare -F "$fn" >/dev/null
done
```

- [ ] **Step 5: Run the full test suite + syntax check**

Run: `bash tests/run.sh && bash -n wow-guard/wow-guard.sh && echo ALLGREEN`
Expected: every test file prints `ALL PASS` and `ALLGREEN`.

- [ ] **Step 6: Commit**

```bash
git add wow-guard/wow-guard.sh tests/test_smoke.sh
git commit -m "feat(wow-guard): integrate Layer C recovery + idle pre-warm into main loop"
```

---

## Task 9: Install/setup scripts + README + end-to-end on-Deck check

**Files:**
- Modify: `wow-guard/install.sh`, `setup.sh`, `README.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: the installer ships `idle-watch.py`; README documents the feature, the one-time Battle.net settings, and the toggle.

- [ ] **Step 1: Install `idle-watch.py` in install.sh**

Edit `wow-guard/install.sh`, after the `wow-guard.sh` copy block, add:
```bash
sed 's/\r$//' "$src/idle-watch.py" > ~/.local/bin/idle-watch.py
chmod +x ~/.local/bin/idle-watch.py
command -v python3 >/dev/null || echo "wow-guard: python3 not found - awake-idle pre-warm will be disabled"
```

- [ ] **Step 2: Ship `idle-watch.py` over SSH in setup.sh**

Edit `setup.sh`: add `idle-watch.py` to the `scp` file list and to the `rm -f` cleanup, i.e.:
```sh
scp "${ssh_opts[@]}" "$dir/wow-guard.sh" "$dir/wow-guard.service" "$dir/install.sh" "$dir/idle-watch.py" "$host:/tmp/"
...
ssh "${ssh_opts[@]}" "$host" 'bash /tmp/install.sh /tmp && rm -f /tmp/wow-guard.sh /tmp/wow-guard.service /tmp/install.sh /tmp/idle-watch.py'
```

- [ ] **Step 3: Verify both installers parse**

Run: `bash -n wow-guard/install.sh && bash -n setup.sh && echo OK`
Expected: `OK`.

- [ ] **Step 4: Add the README section**

In `README.md`, add a new numbered section after the `wow-guard` section:
```markdown
## Keeping WoW: Forever updated in the background

`wow-guard` can keep WoW: Forever patched so pressing **Play** isn't a 10-minute
wait. It does two things, both inside the watchdog (nothing new to run):

- **Never-hang updates.** If a Battle.net download stalls, the watchdog restarts the
  stuck Agent and retries, instead of sitting there forever.
- **Background pre-warm.** When the Deck is awake but idle, it launches Battle.net
  *off-screen* (no window, no controller grab) so pending updates download ahead of
  time, and gets out of the way the moment you touch the controller.

Honest limit: a suspended Deck downloads nothing, so a brand-new huge patch still
downloads when you press Play — but it will *finish* fast instead of hanging.

**One-time Battle.net settings** (needed for background updates to work):
- Settings → Game Install/Update → **Automatic Updates: on**.
- Settings → App → **Minimize to system tray** on close, **Launch minimized**, and
  keep **"Keep me logged in"** checked.
- Settings → Downloads → **Limit download bandwidth: 0** (uncapped).

**Toggle & tuning** (in `wow-guard.service`, default on):
- `WOW_AUTOUPDATE=0` disables all of the above (watchdog behaves as before).
- `IDLE_SECS`, `STALL_SECS`, `UPDATE_RETRIES` tune the idle threshold, stall timeout,
  and retry count.
```

- [ ] **Step 5: End-to-end on-Deck acceptance (manual)**

Install and exercise on the Deck:
```bash
./setup.sh deck@<deck-ip>                      # from the PC, installs everything
ssh deck@<deck-ip> 'systemctl --user is-active wow-guard; tail -n 5 ~/.local/state/wow-guard.log'
```
Acceptance checks (record pass/fail):
1. Service is `active`; log shows `started`.
2. Leave the Deck awake and untouched > `IDLE_SECS`; log shows `pre-warm: launching ... off-screen`; **no window appears, controller still drives the foreground**.
3. Touch the controller; log shows `pre-warm: tearing down`; within a second the prefix is free.
4. Press **Play**; WoW launches and any update **resumes** (doesn't restart from 0) and completes without hanging.
5. Set `WOW_AUTOUPDATE=0` (edit the unit, `systemctl --user daemon-reload && restart`); confirm no pre-warm occurs and behavior matches the old watchdog.

- [ ] **Step 6: Commit**

```bash
git add wow-guard/install.sh setup.sh README.md
git commit -m "feat: ship background auto-update (idle reader install + docs)"
```

---

## Self-Review notes

- **Spec coverage:** Layer C → Tasks 4,5,8. Layer B triggers (wake unchanged + awake-idle) → Tasks 6,8. Layer A invisible launch + fallback → Task 7 (headless; falls back to "disabled, Layer C still ships" if on-Deck validation fails). Update-state detection → Task 4. Toggle default-on → Tasks 2,3. Safety/non-intrusiveness (kill on input/suspend/WoW, login-aware) → Tasks 7,8. Config knobs → Task 2. Testing/validation → every task + Tasks 1 and 9 for on-Deck. Repo changes → all files from the spec covered.
- **Refinement vs. spec (flagged):** the spec said pre-warm "on wake AND awake-idle." The Proton **prefix lock** (research) makes an on-wake headless pre-warm collide with a fast grab→Play, so on-wake is handled by letting the already-running Battle.net resume its auto-download (existing behavior) and the headless pre-warm is reserved for awake-idle windows. Net effect for the user is the same or better; called out in Task 8 Step 2.
- **Prerequisite:** Task 1 must run on the Deck first to confirm the Agent-log directory, Proton build name, sniper path, headless support, and a readable input node; the CONFIG defaults are research-derived and checked against it.
- **Placeholder scan:** none — every code step shows complete code; on-Deck steps give exact commands + expected output.
