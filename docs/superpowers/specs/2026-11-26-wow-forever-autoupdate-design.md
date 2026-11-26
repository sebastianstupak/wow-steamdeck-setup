# WoW: Forever background auto-update — design

**Date:** 2026-11-26
**Status:** Approved (brainstorming) — ready for implementation plan
**Component:** `wow-guard` watchdog (this repo)

## Problem

Two related pains when playing WoW: Forever through the Battle.net launcher on a
Steam Deck:

1. **Updating hangs "forever."** A recent play session couldn't get WoW: Forever to
   update at all — Battle.net sat there and never finished. (Likely the same
   dead-network-after-sleep / stalled-Agent class of failure the watchdog already
   fights for *launch*, but applied to the *update/download* step.)
2. **Updates aren't ready when you want to play.** Picking up the Deck and waiting
   tens of minutes for an update before you can play.

The goal: keep WoW: Forever's update downloaded ahead of time so **Play** is fast,
and make the update itself **never hang forever again**.

## Hard constraints (the physics)

These shape everything and are stated so the implementation never pretends
otherwise:

- **Updates come through Battle.net, not Steam.** Battle.net is a *non-Steam
  shortcut*; Steam does not manage its updates and exposes no "auto-update" flag
  for it. There is no Steam setting to read for this game.
- **A suspended Steam Deck runs nothing.** The user's pattern is
  suspend → grab → play fast, and the Deck is almost always suspended. Nothing can
  download during suspend. Updates can only run while the Deck is **awake**.
- **Therefore a brand-new large patch cannot be fully pre-downloaded** — the Deck
  was asleep until you grabbed it. Most of the "no more 10-minute wait" win comes
  from making the at-Play update **reliable and fast**; pre-warm covers the rest
  only when there has been some awake time.
- **Battle.net grabs screen + controller.** In Gaming Mode any launched app takes
  the screen and reads the controller (README problem #2). "Background" therefore
  means we must *actively* keep it out of the way.
- **Cannot be validated from the dev machine.** The off-screen launch in particular
  must be tried on the actual Deck; the design must degrade gracefully if a given
  mechanism doesn't work there.

## Non-goals

- Updating during suspend (impossible).
- Bypassing Battle.net to patch WoW from the CDN directly (fragile, out of scope).
- Changing anything outside `~/.local` or installing system packages on SteamOS
  (must survive SteamOS updates, same as today's watchdog).
- Reading a real "Steam auto-update setting" for Battle.net (does not exist).

## Decisions (locked during brainstorming)

| Decision | Choice |
| --- | --- |
| Overall approach | **Layered A + B + C** (reliability core + pre-warm triggers + invisible launch with fallback) |
| Pre-warm triggers | **On wake AND after an awake-idle window** |
| Default state | **ON by default**, mimicking Steam's "always keep this game updated" default, with a documented off switch |
| Play collision (pre-warm mid-download, user presses Play) | **Reuse the in-flight update** — no restart, no double download |
| Home for the code | Inside `wow-guard` (systemd `--user`), nothing outside `~/.local` |

## Architecture

All behavior lives in the existing `wow-guard` watchdog loop (plus an optional
small helper for readability). No new long-running services. Three layers:

### Layer C — reliable update core (foundation)

When Battle.net is updating WoW — whether the user pressed Play or a pre-warm
started it — watch the **Battle.net Agent** download:

- If the network is down, wait for it (reuse the existing `wait_network`).
- Track download **progress**. If there is **no progress for `STALL_SECS`**
  (configurable; the "couldn't update forever" signature), tear down the stuck
  Agent/launcher using the existing `kill_bnet_stack`, then restart and retry up to
  `UPDATE_RETRIES` times.
- After the retries are exhausted, log a single clear line
  (e.g. "update stalled — start it manually") and stop retrying. Never loop
  silently forever.

This layer is what directly fixes the reported bug and is the most important part.

### Layer B — pre-warm triggers

Extend the watchdog (which already detects wake-from-sleep via the loop `gap`) so
that, **when the toggle is on**:

- **On wake:** kick a background update so it is downloading before/while the user
  reaches Play.
- **After an awake-idle window:** if the Deck has been awake with **no input for
  `IDLE_SECS`** and WoW is not running, kick a background update.
- **Play collision:** if the user presses Play (a real foreground Battle.net/WoW
  launch) while a pre-warm update is in flight, **reuse** that in-flight update —
  do not kill and restart it. This relies on the watchdog's existing single-stack
  coordination (one WoW, one Battle.net), extended so a pre-warm instance is
  recognized and adopted rather than treated as a duplicate to kill.

Idle detection must work in the gamescope/Gaming-Mode session without new packages
(e.g. via available input-idle signals); the exact source is confirmed during the
validation step, with a safe fallback of "wake-trigger only" if no reliable idle
signal is found on the Deck.

### Layer A — invisible launch, self-falling-back

The pre-warm tries to run Battle.net so it never grabs the screen or controller.
Because a hand-rolled off-screen Proton launch is genuinely fragile on SteamOS,
the launch strategy is **tiered and self-detecting**, and the code auto-falls-back:

1. **Preferred — off-screen:** render Battle.net to a throwaway off-screen display
   (nested `gamescope --headless`, or equivalent available on the Deck) **and/or**
   launch it without attaching the Steam Input controller profile, combined with
   Battle.net's own "launch minimized to tray." Goal: it never appears and never
   sees the controller.
2. **Fallback — handled visible:** if the off-screen path fails on this Deck, fall
   back to a visible launch that **only runs while the user is idle** and **bails
   immediately** when real input resumes or the user heads to Play.

The implementation plan includes a **short on-Deck validation spike** to determine
which mechanism actually works, and the chosen path is recorded. The running code
must detect failure of the preferred path at runtime and drop to the fallback so
the user is never stuck with a broken invisible launch.

## Update-state detection

Read Battle.net / **Agent** logs inside the existing Proton prefix (the watchdog
already parses `.../AppData/Local/Battle.net/Logs`) to distinguish:

- **updating** (download in progress, with a progress figure to detect stalls),
- **up-to-date** (nothing to do — don't launch, or quit promptly),
- **stalled** (no progress → Layer C recovery),
- **login needed** (saved session expired — a headless launch *cannot* resolve
  this; log it and defer to the normal visible sign-in instead of looping).

Exact log file paths and marker strings are **confirmed during the on-Deck
validation step**; the design commits to the mechanism, not to unverified strings.

## Safety / non-intrusiveness rules

- **Never fights the user:** if real input is happening, or WoW is running, the
  pre-warm backs off / tears down.
- **Login-wall aware:** expired Battle.net session → log and defer to visible
  sign-in; do not retry invisibly.
- **One of everything:** reuse the watchdog's single-WoW / single-Battle.net
  teardown so pre-warm + Play can never leave two stacks running.
- **Bounded work:** all retry loops are bounded (`UPDATE_RETRIES`) and logged; no
  unbounded loops.

## Configuration

A single toggle plus tunables, surfaced via the service environment and/or a flag
file, and documented in the README:

| Name | Default | Meaning |
| --- | --- | --- |
| `WOW_AUTOUPDATE` | `1` (on) | Master switch. On mimics Steam's "always keep updated" default; set to `0` to disable all pre-warm/auto-update behavior. |
| `IDLE_SECS` | TBD-in-plan (e.g. ~180) | Awake-idle time before a pre-warm may start. |
| `STALL_SECS` | TBD-in-plan (e.g. ~120) | No-progress time that marks a download as stalled. |
| `UPDATE_RETRIES` | TBD-in-plan (e.g. 3) | Bounded retry count for a stalled/failed update. |

Defaults are finalized in the implementation plan; all are overridable the same way
`BNET_APPID` / `RESUME_MIN` are today. With `WOW_AUTOUPDATE=0`, behavior is
identical to today's watchdog.

## Repo changes

- `wow-guard/wow-guard.sh` — update-watch (Layer C) + pre-warm triggers (Layer B) +
  tiered invisible launch (Layer A).
- `wow-guard/prewarm.sh` — **optional** small helper, only if it keeps the watchdog
  readable (the launch/teardown of a pre-warm instance).
- `wow-guard/wow-guard.service` — add an `Environment=WOW_AUTOUPDATE=1` line (and any
  other tunables) so the toggle is visible and editable in the unit.
- `README.md` — a short "Auto-update / pre-warm" section: what it does, the honest
  suspend caveat, and how to turn it off / tune it.
- `install.sh` / `setup.sh` — no change expected (they already copy the whole
  `wow-guard` folder and restart the service); confirm during implementation.

## Testing & validation

Because the real target is a Steam Deck in Gaming Mode:

- **Static checks:** `bash -n` on all scripts (the installer already does this);
  shellcheck if available.
- **Logic-level checks off-Deck:** exercise state transitions
  (updating → stalled → retry → give-up; pre-warm → Play adoption; login-needed →
  defer) by faking the Agent-log inputs the functions read, so the decision logic is
  verifiable without a Deck.
- **On-Deck validation spike (in the plan):**
  1. Confirm Agent-log location + marker strings for updating / up-to-date /
     stalled / login-needed.
  2. Determine which invisible-launch mechanism works (off-screen vs
     no-controller-profile + minimize-to-tray) and record it; wire the fallback.
  3. Confirm an idle signal exists; else fall back to wake-trigger-only.
  4. End-to-end: suspend → wake → observe a pre-warm update run and complete; then
     press Play and confirm it's fast and the in-flight update was reused, not
     restarted.
- **Regression:** with `WOW_AUTOUPDATE=0`, the watchdog behaves exactly as before.

## Open items to resolve in the plan (not blockers)

- Final numeric defaults for `IDLE_SECS` / `STALL_SECS` / `UPDATE_RETRIES`.
- Exact idle-input signal available in the gamescope session.
- Exact Agent-log markers (from the validation spike).
- Whether `prewarm.sh` is worth splitting out or the logic stays inline.
