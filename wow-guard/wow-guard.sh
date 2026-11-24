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
APPID=$(find_appid) || {
    echo "wow-guard: no Battle.net Proton prefix found; add Battle.net as a non-Steam game first" >&2
    exit 1
}
# printf %u prints the unsigned value; the id is > 2^63 so plain $(()) would wrap negative
GAME_ID=$(printf '%u' "$(((APPID << 32) | 0x02000000))")
APPID_URL="steam://rungameid/$GAME_ID"
PFX="$HOME/.local/share/Steam/steamapps/compatdata/$APPID/pfx/drive_c"
BNET_LOGS="$PFX/users/steamuser/AppData/Local/Battle.net/Logs"
# Anchored so it only matches the real Battle.net process, never a shell whose
# command line merely mentions it.
BNET_RE='^C:.Program Files .x86..Battle\.net.Battle\.net\.exe --from-launcher'
PREFIX_RE="compatdata/$APPID"
RESUME_MIN=300
LOG="$HOME/.local/state/wow-guard.log"

mkdir -p "$(dirname "$LOG")"
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 200000 ] && tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

bnet_running() { pgrep -f "$BNET_RE" >/dev/null; }

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

declare -A seen
for p in $(pgrep -x Wow.exe); do seen[$p]=1; done   # leave already-running WoW alone
log "started (appid $APPID; existing WoW: ${!seen[*]})"
last=$(date +%s)

while sleep 1; do
    now=$(date +%s)
    gap=$((now - last)); last=$now

    # 2. woke up from a long sleep
    if [ $gap -gt $RESUME_MIN ]; then
        log "Deck woke up after $((gap / 60)) min"
        if ! pgrep -x Wow.exe >/dev/null && bnet_running; then
            wait_network || log "network slow to return after wake"
            pgrep -x Wow.exe >/dev/null || restart_bnet "after sleep"
        fi
        last=$(date +%s)
        continue
    fi

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
