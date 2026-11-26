#!/bin/bash
# wow-guard: runs on the Steam Deck as a systemd --user service (see install.sh).
#  1. Only one WoW: a second Wow.exe is closed as soon as it appears (it is still
#     loading, so nothing is lost).
#  2. Fresh Battle.net after sleep: after the Deck sleeps, Battle.net can still say
#     "Online" while its connection is dead, and the network is gone for a while, so
#     its launcher hangs before it ever starts the signed-in client. When the Deck
#     wakes from a sleep longer than RESUME_MIN seconds and WoW is not running,
#     Battle.net is restarted once the network is back.
#  3. Stale Battle.net caught at Play: if WoW is started without a login token
#     (no -launcherlogin AND Battle.net logged "SSO Token generation error" just now),
#     that WoW - which would only show its login screen - is closed and Battle.net
#     restarted, so the next Play works. Anything unexpected -> do nothing.
# Log: ~/.local/state/wow-guard.log

# The Battle.net non-Steam shortcut's Steam appid (its Proton prefix). Auto-detected
# from the compatdata folder that holds a Battle.net install; set BNET_APPID to
# override. A non-Steam shortcut's 64-bit rungameid is (appid << 32) | 0x02000000.
find_appid() {
    [ -n "$BNET_APPID" ] && { echo "$BNET_APPID"; return 0; }
    local d
    for d in "$HOME/.local/share/Steam/steamapps/compatdata"/*/; do
        [ -e "$d/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe" ] && { basename "$d"; return 0; }
    done
    return 1
}
if [ -n "${SOURCING_FOR_TEST:-}" ]; then
    # Sourced on a dev machine for unit tests: no Steam Deck prefix exists, so
    # skip the resolve-or-exit below and the dependent path/GAME_ID setup, and
    # use harmless placeholders instead.
    APPID=TEST
    PFX=/tmp/none
    GAME_ID=0
    APPID_URL="steam://rungameid/0"
else
    APPID=$(find_appid) || {
        echo "wow-guard: no Battle.net Proton prefix found; add Battle.net as a non-Steam game first" >&2
        exit 1
    }
    # printf %u prints the unsigned value; the id is > 2^63 so plain $(()) would wrap negative
    GAME_ID=$(printf '%u' "$(((APPID << 32) | 0x02000000))")
    APPID_URL="steam://rungameid/$GAME_ID"
    PFX="$HOME/.local/share/Steam/steamapps/compatdata/$APPID/pfx/drive_c"
fi
BNET_LOGS="$PFX/users/steamuser/AppData/Local/Battle.net/Logs"
# Anchored so it only matches the real Battle.net process, never a shell whose
# command line merely mentions it.
BNET_RE='^C:.Program Files .x86..Battle\.net.Battle\.net\.exe --from-launcher'
PREFIX_RE="compatdata/$APPID"
RESUME_MIN=300
LOG="$HOME/.local/state/wow-guard.log"

# ---- auto-update config -----------------------------------------------------
BNET_LAUNCHER_LOGS="$PFX/users/steamuser/AppData/Local/Battle.net/Logs"
# The WoW install Data dir grows while an update downloads. This byte growth is the one
# reliable progress signal: Battle.net's Agent logs do NOT mark a 'wowf' update complete
# (only its own 'agent' self-updates log "completed"), and the Operations-log mtime stays
# frozen for long stretches mid-download - both confirmed on-Deck. So we watch bytes.
WOWDATA="$PFX/Program Files (x86)/World of Warcraft/Data"
WOW_AUTOUPDATE="${WOW_AUTOUPDATE:-1}"
IDLE_SECS="${IDLE_SECS:-180}"            # awake-idle time before a pre-warm may start
SAMPLE_SECS="${SAMPLE_SECS:-30}"         # how often to sample the download size
GROWTH_MIN="${GROWTH_MIN:-1048576}"      # >=1 MiB between samples counts as "downloading"
QUIET_SECS="${QUIET_SECS:-150}"          # no growth this long after it HAD grown -> finished
UPTODATE_SECS="${UPTODATE_SECS:-240}"    # no growth at all this long -> nothing to download
PREWARM_MAX_SECS="${PREWARM_MAX_SECS:-3600}"  # hard cap on a single pre-warm session
COOLDOWN_SECS="${COOLDOWN_SECS:-1800}"   # min gap between pre-warm sessions (don't churn when up to date)
INPUT_STAMP="$HOME/.local/state/wow-guard.input"

# ---- stuck-update auto-heal -------------------------------------------------
# Battle.net updates wedge forever when AddOns contain files it TACT-manages but that lack
# the ':bnet_tact' marker (e.g. community packs copied in, not downloaded) - the Agent spins
# ~100% CPU stat'ing the missing marker thousands of times/sec, no disk writes, stuck at 97%.
# Confirmed on-Deck. Auto-heal detects that signature, quarantines the offending addon so the
# update can finish, and logs it. Toggle off with WOW_AUTOHEAL=0.
WOW_AUTOHEAL="${WOW_AUTOHEAL:-1}"
STUCK_SECS="${STUCK_SECS:-180}"          # Agent spinning with ZERO disk writes this long = stuck
RESTORE_DELAY="${RESTORE_DELAY:-120}"    # after a heal, wait this long (update finishing) before restoring
THRASH_SECS="${THRASH_SECS:-600}"        # heals closer than this = thrash -> stop auto-restoring
ADDON_FILE_MAX="${ADDON_FILE_MAX:-3000}" # an addon with more files than this is a content pack
                                         # (the marker-less kind that hangs updates); normal addons
                                         # have <1k. On-Deck: culprits 12k-20k, biggest legit 945.
WOW_ROOT="$PFX/Program Files (x86)/World of Warcraft"
QUARANTINE_DIR="$HOME/wow-backups/wow-guard-quarantine"
ADDONS_DIR=""   # resolved to the flavor's Interface/AddOns (e.g. _forever_/Interface/AddOns)
for _f in "$WOW_ROOT"/*/Interface/AddOns; do [ -d "$_f" ] && { ADDONS_DIR="$_f"; break; }; done

if [ -z "${SOURCING_FOR_TEST:-}" ]; then   # skip filesystem side effects when sourced for tests
    mkdir -p "$(dirname "$LOG")"
    [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 200000 ] && tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

bnet_running() { pgrep -f "$BNET_RE" >/dev/null; }

# Total bytes of the WoW install Data dir. Grows while an update downloads; this is the
# activity/progress signal the pre-warm samples. Echoes a number (0 if the dir is missing).
wow_data_bytes() { # $1 = Data dir (defaults to $WOWDATA)
    local d="${1:-$WOWDATA}" b
    b=$(du -sb "$d" 2>/dev/null | cut -f1)
    case "$b" in ''|*[!0-9]*) echo 0 ;; *) echo "$b" ;; esac
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

# Is background auto-update enabled? (default on; WOW_AUTOUPDATE=0 disables all new behavior)
autoupdate_enabled() { [ "${WOW_AUTOUPDATE:-1}" != "0" ]; }

# Did Battle.net fail to get a login token in the last 3 minutes? (log times are UTC)
token_error_recent() {
    local f; f=$(ls -t "$BNET_LOGS"/battle.net-*.log 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    local now; now=$(date -u +%s)
    grep -a "SSO Token generation error" "$f" | tail -3 | while read -r _ d t _; do
        ts=$(date -u -d "$d ${t%.*}" +%s 2>/dev/null) || continue
        [ $((now - ts)) -lt 180 ] && echo yes
    done | grep -q yes
}

# The network is dead for a while right after the Deck wakes; launching Battle.net
# then makes its launcher hang before it ever starts the signed-in client.
wait_network() {
    for _ in $(seq 1 30); do
        ping -c1 -W2 us.actual.battle.net >/dev/null 2>&1 && return 0
        getent hosts us.actual.battle.net >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# Kill the whole Battle.net stack, not just the signed-in client: a stuck launcher
# or agent (no Battle.net.exe yet) would otherwise survive. Wine-side exes have a
# Windows-path cmdline (anchored ^C:, self-safe); the Linux side is in the prefix.
kill_bnet_stack() {
    pkill -9 -f "$BNET_RE" 2>/dev/null
    pkill -9 -f '^C:.Program Files .x86..Battle\.net' 2>/dev/null
    pkill -9 -f '^C:.ProgramData.Battle\.net' 2>/dev/null
    local p c
    for p in $(pgrep -f "$PREFIX_RE/pfx" 2>/dev/null); do
        c=$(cat "/proc/$p/comm" 2>/dev/null)
        case "$c" in bash | sh | ssh | pgrep | pkill | grep | wow-guard.sh) continue ;; esac
        kill -9 "$p" 2>/dev/null
    done
}

STEAM="$HOME/.local/share/Steam"
# Resolve the shortcut's Proton build name from CompatToolMapping, then its proton script.
resolve_proton_dir() {
    [ -n "$PROTON_DIR" ] && { echo "$PROTON_DIR"; return; }
    local name
    name=$(grep -A3 "\"$APPID\"" "$STEAM/config/config.vdf" 2>/dev/null | sed -n 's/.*"name"[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$name" ] && [ -d "$STEAM/compatibilitytools.d/$name" ] && { echo "$STEAM/compatibilitytools.d/$name"; return; }
    ls -d "$STEAM/compatibilitytools.d/"*/ 2>/dev/null | head -1 | sed 's#/$##'   # fallback: first custom build
}
# Resolve the Steam Linux Runtime the Proton build REQUIRES (toolmanifest require_tool_appid
# -> that appid's appmanifest installdir). GE-Proton 11+ needs the newer runtime
# (SteamLinuxRuntime_4, python 3.13); the sniper runtime ships python 3.9 and makes proton
# fail with "cannot import name 'Self' from typing" - confirmed on-Deck. Hardcoding sniper
# is wrong; derive it.
resolve_runtime_entry() {
    [ -n "$RUNTIME_ENTRY" ] && { echo "$RUNTIME_ENTRY"; return; }
    local proton appid dir d
    proton=$(resolve_proton_dir)
    appid=$(sed -n 's/.*"require_tool_appid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$proton/toolmanifest.vdf" 2>/dev/null | head -1)
    if [ -n "$appid" ]; then
        dir=$(sed -n 's/.*"installdir"[[:space:]]*"\([^"]*\)".*/\1/p' "$STEAM/steamapps/appmanifest_$appid.acf" 2>/dev/null | head -1)
        [ -n "$dir" ] && [ -x "$STEAM/steamapps/common/$dir/_v2-entry-point" ] && { echo "$STEAM/steamapps/common/$dir/_v2-entry-point"; return; }
    fi
    for d in SteamLinuxRuntime_4 SteamLinuxRuntime_sniper; do   # fallback: newest runtime present
        [ -x "$STEAM/steamapps/common/$d/_v2-entry-point" ] && { echo "$STEAM/steamapps/common/$d/_v2-entry-point"; return; }
    done
}
BNET_EXE="${BNET_EXE:-$PFX/Program Files (x86)/Battle.net/Battle.net Launcher.exe}"
PREWARM_MARK='gamescope --backend headless'          # unique enough to find/kill the pre-warm
PREWARM_STAMP="$HOME/.local/state/wow-guard.prewarm"  # launch time, for age/cap
PREWARM_LOG="$HOME/.local/state/wow-guard-prewarm.log"  # proton/gamescope noise (own file)

# Build the off-screen launch command (printed so it is unit-testable without launching).
# Only $BNET_EXE is quoted: it alone contains spaces/parens ("Program Files (x86)/...").
# $STEAM/$runtime/$proton are space-free on a Deck (/home/deck/...), so they are left
# unquoted so the command tokenizes correctly when run via `bash -c "$(prewarm_cmd)"`.
# Do NOT add quotes around $runtime/$proton - that breaks word-splitting of the run verb.
prewarm_cmd() {
    local proton runtime; proton=$(resolve_proton_dir); runtime=$(resolve_runtime_entry)
    printf '%s' "gamescope --backend headless -W 1280 -H 720 -- env " \
        "STEAM_COMPAT_DATA_PATH=$STEAM/steamapps/compatdata/$APPID " \
        "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM " \
        "$runtime --verb=run -- $proton/proton run '$BNET_EXE' --autostarted"
}

# Stateless detection/teardown by process marker (setsid's $! is unreliable; a marker
# also survives a watchdog restart). Teardown reuses the existing kill_bnet_stack.
prewarm_running() { pgrep -f "$PREWARM_MARK" >/dev/null 2>&1; }
prewarm_age() { local s; s=$(cat "$PREWARM_STAMP" 2>/dev/null) || { echo 0; return; }
    case "$s" in ''|*[!0-9]*) echo 0; return ;; esac; echo $(( $(date +%s) - s )); }

# Download-sampling state for the running pre-warm (reset at each launch); PW_LAST_END is
# when the last pre-warm closed, for the cooldown so an up-to-date game doesn't churn.
PW_LAST_BYTES=0; PW_LAST_SAMPLE=0; PW_LAST_GROWTH=0; PW_SAW_GROWTH=0; PW_LAST_END=0

prewarm_launch() {
    prewarm_running && return 0
    login_needed "$BNET_LAUNCHER_LOGS" && { log "pre-warm skipped: Battle.net login expired - sign in once"; return 1; }
    bnet_running && { log "pre-warm skipped: Battle.net already running"; return 1; }
    log "pre-warm: launching Battle.net off-screen to update"
    : "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"; export XDG_RUNTIME_DIR   # gamescope needs it
    # proton/gamescope are noisy (color codes, Xalia tracebacks) -> own file, overwritten
    # each launch, so the main log stays clean text.
    nohup bash -c "$(prewarm_cmd)" >"$PREWARM_LOG" 2>&1 &
    local now; now=$(date +%s)
    echo "$now" > "$PREWARM_STAMP"
    PW_LAST_BYTES=$(wow_data_bytes); PW_LAST_SAMPLE=$now; PW_LAST_GROWTH=$now; PW_SAW_GROWTH=0
}

prewarm_kill() {
    prewarm_running || { rm -f "$PREWARM_STAMP"; return 0; }
    log "pre-warm: tearing down off-screen Battle.net (releasing prefix)"
    pkill -TERM -f "$PREWARM_MARK" 2>/dev/null
    sleep 2
    kill_bnet_stack
    rm -f "$PREWARM_STAMP"
    PW_LAST_END=$(date +%s)   # start the cooldown before the next pre-warm
}

IDLE_PID=""
IDLE_DISABLED=""   # latched once the reader can't run, so we don't respawn it every second

# Start (and keep alive) the evdev idle reader. Disables the awake-idle layer gracefully
# (latched) if python3 or a readable input device is unavailable (wake handling is unaffected).
start_idle_watch() {
    autoupdate_enabled || return 0
    [ -n "$IDLE_DISABLED" ] && return 0
    [ -n "$IDLE_PID" ] && kill -0 "$IDLE_PID" 2>/dev/null && return 0
    command -v python3 >/dev/null 2>&1 || { IDLE_DISABLED=1; log "idle-watch: python3 not found - awake-idle pre-warm disabled (wake handling unaffected)"; return 0; }
    python3 "$HOME/.local/bin/idle-watch.py" "$INPUT_STAMP" >>"$LOG" 2>&1 &
    IDLE_PID=$!
    sleep 1
    kill -0 "$IDLE_PID" 2>/dev/null || { IDLE_PID=""; IDLE_DISABLED=1; log "idle-watch unavailable - awake-idle pre-warm disabled (wake handling unaffected)"; }
}

# Manage a running pre-warm: stop it the instant the user is back (input), WoW starts, or a
# hard cap is hit; otherwise sample the download size and stop when it finishes (no growth
# for QUIET_SECS after it HAD grown) or when there was nothing to download (no growth at all
# for UPTODATE_SECS). A stalled download is handled implicitly: we close, and the next idle
# window relaunches a fresh Battle.net that resumes the partial download from disk (the
# prefix lock means only one program runs in it at a time, so we must yield before Play).
manage_prewarm() { # $1 = wow_up, $2 = idle_secs
    local wow_up="$1" idle="$2" now age cur
    now=$(date +%s); age=$(prewarm_age)
    if [ "$wow_up" = 1 ] || [ "$idle" -lt "$IDLE_SECS" ] || [ "$age" -ge "$PREWARM_MAX_SECS" ]; then
        prewarm_kill; return
    fi
    [ $((now - PW_LAST_SAMPLE)) -ge "$SAMPLE_SECS" ] || return   # only sample periodically
    cur=$(wow_data_bytes)
    if [ "$PW_LAST_BYTES" -gt 0 ] && [ $((cur - PW_LAST_BYTES)) -ge "$GROWTH_MIN" ]; then
        PW_SAW_GROWTH=1; PW_LAST_GROWTH=$now
        log "pre-warm: downloading (+$(( (cur - PW_LAST_BYTES) / 1048576 )) MiB)"
    fi
    PW_LAST_BYTES=$cur; PW_LAST_SAMPLE=$now
    if [ "$PW_SAW_GROWTH" = 1 ] && [ $((now - PW_LAST_GROWTH)) -ge "$QUIET_SECS" ]; then
        log "pre-warm: download idle ${QUIET_SECS}s - finished, closing"; prewarm_kill
    elif [ "$PW_SAW_GROWTH" = 0 ] && [ "$age" -ge "$UPTODATE_SECS" ]; then
        log "pre-warm: no download activity - already up to date, closing"; prewarm_kill
    fi
}

# One iteration of the auto-update state machine. Extracted so it is unit-testable with
# stubbed side-effects. $1 = wow_up (1 if WoW is running, else 0).
autoupdate_tick() {
    autoupdate_enabled || return 0
    local wow_up="$1"
    local idle; idle=$(idle_seconds "$INPUT_STAMP")
    start_idle_watch
    if prewarm_running; then
        manage_prewarm "$wow_up" "$idle"
    elif [ -n "$IDLE_PID" ] && should_prewarm 1 "$wow_up" "$idle" "$IDLE_SECS" \
         && [ $(( $(date +%s) - PW_LAST_END )) -ge "$COOLDOWN_SECS" ]; then
        prewarm_launch
    fi
}

# ---- stuck-update auto-heal -------------------------------------------------
# A sample looks like a stuck spin: the Agent burned >50% of a core over the window AND wrote
# zero bytes to disk (install frozen). Pure function so the threshold is unit-testable.
spin_sample_stuck() { # $1 cpu_ticks_delta  $2 write_bytes_delta  $3 window_secs
    [ "${3:-0}" -gt 0 ] 2>/dev/null || return 1
    [ "${1:-0}" -ge $(( 50 * $3 )) ] 2>/dev/null && [ "${2:-0}" -eq 0 ] 2>/dev/null
}

# Identify the addon(s) wedging the update, WITHOUT ptrace (strace can't attach to the Agent
# unless kernel.yama.ptrace_scope == 0, which it isn't by default). The culprits are marker-less
# content packs with a huge file count (12k-20k observed) vs <1k for normal addons - a clean,
# wide gap. Echo every addon folder over ADDON_FILE_MAX files; removing them all at once lets
# the update finish (removing just one only reveals the next, confirmed on-Deck).
stuck_addons() { # $1 = agent pid (unused; kept for interface stability)
    [ -n "$ADDONS_DIR" ] || return 0
    local d c
    for d in "$ADDONS_DIR"/*/; do
        [ -d "$d" ] || continue
        c=$(find "$d" -type f 2>/dev/null | head -"$((ADDON_FILE_MAX + 1))" | wc -l)
        [ "$c" -gt "$ADDON_FILE_MAX" ] && basename "$d"
    done | head -12
}

# Quarantine the offending addon(s) so the wedged update can finish. Reversible: folders are
# MOVED to QUARANTINE_DIR, never deleted. If this was a background pre-warm, relaunch it to
# finish hands-off; otherwise the user's next Play completes the now-unblocked update.
heal_stuck_update() { # $1 = agent pid
    local was_prewarm=0; prewarm_running && was_prewarm=1
    log "auto-heal: update looks stuck (Agent spinning ${STUCK_SECS}s, no disk writes) - diagnosing"
    local offenders; offenders=$(stuck_addons "$1")
    [ -n "$offenders" ] || { log "auto-heal: no AddOns ENOENT loop found - not the marker bug; leaving it alone"; return 1; }
    [ -n "$ADDONS_DIR" ] || { log "auto-heal: AddOns dir not resolved - cannot quarantine"; return 1; }
    mkdir -p "$QUARANTINE_DIR"
    local a moved=0
    for a in $offenders; do
        [ -d "$ADDONS_DIR/$a" ] || continue
        mv "$ADDONS_DIR/$a" "$QUARANTINE_DIR/" && { log "auto-heal: quarantined addon '$a' -> $QUARANTINE_DIR"; moved=$((moved + 1)); }
    done
    [ "$moved" -gt 0 ] || { log "auto-heal: offenders found but none moved"; return 1; }
    local now2; now2=$(date +%s)   # thrash guard: 3rd heal within THRASH_SECS -> stop auto-restoring
    if [ "$HEAL_LAST" -gt 0 ] && [ $((now2 - HEAL_LAST)) -lt "$THRASH_SECS" ]; then HEAL_STREAK=$((HEAL_STREAK + 1)); else HEAL_STREAK=0; fi
    HEAL_LAST=$now2
    [ "$HEAL_STREAK" -ge 2 ] && log "auto-heal: this content keeps re-hanging updates - leaving it in $QUARANTINE_DIR (not auto-restoring); restore it manually once updates settle"
    log "auto-heal: moved $moved addon(s); tearing down the wedged Battle.net"
    kill_bnet_stack; rm -f "$PREWARM_STAMP"; PW_LAST_END=$(date +%s)
    if [ "$was_prewarm" = 1 ]; then
        log "auto-heal: relaunching pre-warm to finish the now-unblocked update"; prewarm_launch
    else
        log "auto-heal: done - relaunch Battle.net / press Play to finish the update"
    fi
    return 0
}

# Per-tick stuck detector state + helpers.
HEAL_SPIN_SINCE=0; HEAL_CPU_PREV=0; HEAL_WB_PREV=0; HEAL_SAMPLE_PREV=0; HEAL_LAST=0; HEAL_STREAK=0
agent_pid() { pgrep -f 'Agent\.exe' | head -1; }

# Restore quarantined addons to AddOns once the update is done and Battle.net has closed, so the
# content is back for gameplay - UNLESS it's thrashing (repeatedly re-hanging; then leave it put).
restore_quarantined() {
    [ "${WOW_AUTOHEAL:-1}" != "0" ] || return 0
    [ -n "$ADDONS_DIR" ] && [ -d "$QUARANTINE_DIR" ] || return 0
    [ -n "$(ls -A "$QUARANTINE_DIR" 2>/dev/null)" ] || return 0   # nothing quarantined
    [ -n "$(agent_pid)" ] && return 0                              # still updating -> wait
    bnet_running && return 0
    [ "$HEAL_LAST" -gt 0 ] && [ $(( $(date +%s) - HEAL_LAST )) -lt "$RESTORE_DELAY" ] && return 0
    [ "$HEAL_STREAK" -ge 2 ] && return 0                           # thrashing -> leave quarantined
    local d n=0
    for d in "$QUARANTINE_DIR"/*; do
        [ -e "$d" ] || continue
        mv "$d" "$ADDONS_DIR/" && n=$((n + 1))
    done
    [ "$n" -gt 0 ] && log "auto-heal: restored $n addon(s) from quarantine to AddOns (update finished)"
}

# Each tick: if the Battle.net Agent spins (CPU, zero disk writes) continuously past STUCK_SECS,
# heal it. A healthy install writes bytes (dw>0); a finished/idle Agent isn't CPU-busy.
autoheal_tick() {
    [ "${WOW_AUTOHEAL:-1}" != "0" ] || return 0
    restore_quarantined   # put healed content back once the update is done + Battle.net closed
    local pid; pid=$(agent_pid)
    [ -n "$pid" ] || { HEAL_SPIN_SINCE=0; return 0; }
    local now; now=$(date +%s)
    [ $((now - HEAL_SAMPLE_PREV)) -ge "$SAMPLE_SECS" ] || return 0
    local cpu wb win dc dw
    cpu=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null); cpu=${cpu:-0}
    wb=$(awk -F': ' '/^write_bytes:/{print $2; exit}' "/proc/$pid/io" 2>/dev/null); wb=${wb:-0}
    if [ "$HEAL_SAMPLE_PREV" -eq 0 ]; then HEAL_CPU_PREV=$cpu; HEAL_WB_PREV=$wb; HEAL_SAMPLE_PREV=$now; return 0; fi
    win=$((now - HEAL_SAMPLE_PREV)); dc=$((cpu - HEAL_CPU_PREV)); dw=$((wb - HEAL_WB_PREV))
    HEAL_CPU_PREV=$cpu; HEAL_WB_PREV=$wb; HEAL_SAMPLE_PREV=$now
    if spin_sample_stuck "$dc" "$dw" "$win"; then
        [ "$HEAL_SPIN_SINCE" -eq 0 ] && HEAL_SPIN_SINCE=$now
        [ $((now - HEAL_SPIN_SINCE)) -ge "$STUCK_SECS" ] && { heal_stuck_update "$pid"; HEAL_SPIN_SINCE=0; }
    else
        HEAL_SPIN_SINCE=0
    fi
}

restart_bnet() {
    log "restarting Battle.net ($1)"
    pkill -f "$BNET_RE"
    for _ in $(seq 1 30); do bnet_running || break; sleep 1; done
    kill_bnet_stack   # also clears a stuck launcher/agent that never started the client
    # wait until Proton for the Battle.net shortcut has fully exited, or Steam ignores the relaunch
    for _ in $(seq 1 60); do pgrep -f "proton waitforexitandrun .*$PREFIX_RE" >/dev/null || break; sleep 1; done
    sleep 3
    export DISPLAY=:0
    XAUTHORITY=$(ls /run/user/1000/xauth_* 2>/dev/null | head -1); [ -n "$XAUTHORITY" ] && export XAUTHORITY
    for try in 1 2 3 4; do
        wait_network || log "network still down (try $try)"
        steam -ifrunning "$APPID_URL" >/dev/null 2>&1 &
        for _ in $(seq 1 45); do sleep 2; bnet_running && { log "Battle.net relaunched (try $try)"; return; }; done
        log "launcher did not sign in (try $try); tearing it down"
        kill_bnet_stack
        sleep 3
    done
    log "Battle.net did not come back - start it from Steam"
}

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

main() {
    declare -A seen
    for p in $(pgrep -x Wow.exe); do seen[$p]=1; done   # leave already-running WoW alone
    log "started (appid $APPID; existing WoW: ${!seen[*]})"
    last=$(date +%s)

    cleanup() { prewarm_kill 2>/dev/null; [ -n "$IDLE_PID" ] && kill "$IDLE_PID" 2>/dev/null; }
    trap cleanup EXIT
    trap 'cleanup; exit 0' TERM INT   # exit so the loop stops promptly on stop/restart
    start_idle_watch

    while sleep 1; do
        now=$(date +%s)
        gap=$((now - last)); last=$now

        # 2. woke up from a long sleep
        if [ $gap -gt $RESUME_MIN ]; then
            log "Deck woke up after $((gap / 60)) min"
            prewarm_running && prewarm_kill
            if ! pgrep -x Wow.exe >/dev/null && bnet_running; then
                wait_network || log "network slow to return after wake"
                pgrep -x Wow.exe >/dev/null || restart_bnet "after sleep"
            fi
            last=$(date +%s)
            continue
        fi

        # background auto-update: runs every second, whether or not WoW is up
        wow_up=0; pgrep -x Wow.exe >/dev/null && wow_up=1
        autoupdate_tick "$wow_up"
        autoheal_tick   # detect+fix an update wedged on a marker-less addon (any Battle.net)
        # autoupdate_tick can take a few seconds (du sampling, prewarm teardown); reset the
        # clock so that latency isn't mistaken for a wake-from-sleep on the next iteration.
        last=$(date +%s)

        mapfile -t pids < <(ps -C Wow.exe -o pid= --sort=start_time | tr -d ' ')
        [ ${#pids[@]} -eq 0 ] && { seen=(); continue; }

        # 1. more than one WoW: keep the oldest
        if [ ${#pids[@]} -gt 1 ]; then
            for p in "${pids[@]:1}"; do
                kill "$p" 2>/dev/null && log "closed second WoW (pid $p); keeping ${pids[0]}"
                seen[$p]=1
            done
        fi

        # 3. new WoW without the Battle.net login hand-off
        p=${pids[0]}
        if [ -z "${seen[$p]}" ]; then
            seen[$p]=1
            if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- '-launcherlogin'; then
                log "WoW pid $p started with Battle.net login"
            elif token_error_recent; then
                kill "$p" 2>/dev/null
                log "closed WoW pid $p: Battle.net could not get a login token"
                restart_bnet "stale login"
            else
                log "WoW pid $p started without -launcherlogin, but no token error logged - left alone"
            fi
        fi
    done
}

# Run the loop only when executed directly, never when sourced for tests.
if [ -z "${SOURCING_FOR_TEST:-}" ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
