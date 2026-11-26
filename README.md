# WoW on a Steam Deck — Battle.net + Proton, done right

Running World of Warcraft through the Battle.net launcher on a Steam Deck in Gaming
Mode works, but two things make it flaky:

1. **After the Deck sleeps, Battle.net's connection is dead.** The Wi-Fi/DNS takes a
   few seconds to come back, but Battle.net may still show "Online" — so relaunching
   it (or pressing **Play**) hangs the launcher during its update/login step and WoW
   never starts, or starts stuck on a login screen.
2. **Battle.net reads the controller and grabs focus.** It can open its own windows
   (friends chat, a file browser) in response to gamepad input and steal focus from
   the game.

This repo has the setup notes and a tiny watchdog, **`wow-guard`**, that fixes #1 so
you can wake the Deck and press Play without dropping to the desktop.

> Built and tested against **WoW: Forever** (a 1.60 client launched through Battle.net)
> on a Steam Deck, but the Proton + watchdog setup is the same for any WoW the
> Battle.net launcher installs.

## TL;DR

1. Add the **Battle.net launcher** as a non-Steam game and run it under **Proton**
   (GE-Proton recommended); install WoW through it.
2. Install the watchdog with one command from your PC: `./setup.sh deck@<deck-ip>`
   (or on the Deck: `cd wow-guard && bash install.sh`).
3. Map the **back grips** in Steam Input (below).
4. In game, use **[Gamepad Grimoire](https://github.com/sebastianstupak/gamepad-grimoire)**
   for a controller cheat sheet and controller-only setup.

## 1. Battle.net as a non-Steam game

In **Desktop Mode**:

- **Steam → Games → Add a Non-Steam Game to My Library**, and add the Battle.net
  **Setup/Launcher** `.exe` (if you don't have it yet, add any `.exe`, point the
  shortcut's *Target* at `Battle.net-Setup.exe`, run it once to install, then point
  the *Target* back at `Battle.net Launcher.exe`).
- Shortcut → **Properties → Compatibility → Force the use of a specific Steam Play
  compatibility tool**. Stock Proton works; **GE-Proton** (install it with
  [ProtonUp-Qt](https://davidotek.github.io/protonup-qt/)) is noticeably more reliable
  for the Battle.net launcher — this setup runs GE-Proton 11-12.
- Launch the shortcut, sign in to Battle.net, and install WoW.

The game now lives in the shortcut's Proton prefix:

```
~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/drive_c/Program Files (x86)/...
```

`<appid>` is the shortcut's generated Steam appid. The watchdog finds it
automatically; to see it yourself, it's the `compatdata` folder that contains
`.../Battle.net/Battle.net Launcher.exe`.

## 2. The after-sleep fix — `wow-guard`

`wow-guard` is a `systemd --user` service (so it survives SteamOS updates — nothing
goes outside `~/.local`). It:

- **Restarts Battle.net after a long sleep, waiting for the network first** — the root
  cause of the flakiness is launching into a dead network.
- **Recovers a hung launcher.** If the launcher never reaches the signed-in client, it
  tears the whole stack down and retries. (The client runs under Wine with a `C:\…`
  command line, so a naive "kill everything in the prefix" misses it — the watchdog
  kills the Wine-side exes by their Windows path *and* the Linux-side launch.)
- **Fixes a login-token miss.** If WoW starts without `-launcherlogin` and Battle.net
  just logged an `SSO Token generation error`, that WoW (which would only show a login
  screen) is closed and Battle.net restarted so the next Play works.
- **Keeps a single WoW** running (closes a duplicate while it's still loading).

**Install it in one command from your PC** (after enabling SSH on the Deck — see
below). This copies the files over and installs + starts the service:

```sh
./setup.sh deck@<deck-ip>            # uses your default SSH key / agent
./setup.sh deck@<deck-ip> ~/.ssh/steamdeck
```

Or, on the Deck itself:

```sh
cd wow-guard && bash install.sh
```

Either way it auto-detects the Battle.net appid (set `BNET_APPID=<id>` to override),
and re-running updates the watchdog in place. Logs go to `~/.local/state/wow-guard.log`:

```sh
systemctl --user status wow-guard
tail -f ~/.local/state/wow-guard.log
```

## 3. Keeping WoW: Forever updated in the background

`wow-guard` can keep WoW: Forever patched so pressing **Play** isn't a 10-minute
wait. When the Deck is awake but **idle**, the watchdog launches Battle.net
*off-screen* — a nested headless `gamescope` running the game's own Proton, started
outside Steam so it takes **no screen and no controller** — lets its pending update
download, and closes it the instant you touch the controller or start WoW (so the
prefix is free for Play, which resumes right where the download left off). It watches
the install's **download size** to know when it's downloading vs. finished (Battle.net
doesn't log WoW update completion, so bytes are the signal). Nothing new to run — it's
all inside the watchdog.

A stalled download heals itself: the pre-warm closes, and the next idle window starts
a fresh Battle.net that resumes the partial download — so it never hangs "forever."

Honest limit: a suspended Deck downloads nothing, so a brand-new huge patch still
downloads when you press Play — the pre-warm just keeps that from happening often by
staying current whenever the Deck is awake and idle.

**One-time Battle.net settings** (needed for background updates to work):
- Settings → Game Install/Update → **Automatic Updates: on**.
- Settings → App → **Minimize to system tray** on close, **Launch minimized**, and
  keep **"Keep me logged in"** checked.
- Settings → Downloads → **Limit download bandwidth: 0** (uncapped).

**Toggle & tuning** (in `wow-guard.service`, default on):
- `WOW_AUTOUPDATE=0` disables all of the above (watchdog behaves as before).
- `IDLE_SECS` (idle time before a pre-warm starts), `SAMPLE_SECS`/`QUIET_SECS` (how it
  decides a download is done), and `PREWARM_MAX_SECS` (hard cap per session) tune it.
- The pre-warm's own (noisy) output goes to `~/.local/state/wow-guard-prewarm.log`;
  the watchdog's log stays at `~/.local/state/wow-guard.log`.

## 4. Steam Input — controller and back grips

Give the Battle.net shortcut a **Gamepad** controller layout in Steam Input, so WoW
sees a normal controller (WoW's gamepad support does the rest; the in-game
[Gamepad Grimoire](https://github.com/sebastianstupak/gamepad-grimoire) addon shows
what each button is bound to).

The four **back grips (L4 / L5 / R4 / R5)** are not standard gamepad buttons, so map
them to keyboard keys in Steam Input. A good starting point:

| Grip | Mapped to | Use |
| --- | --- | --- |
| L5 | `Escape` | close menus / cancel |
| L4 | `Enter` | confirm / open chat |
| R4 | Steam on-screen keyboard | type without a keyboard |
| R5 | your choice (e.g. `Tab` target) | |

> Because the grips are handled by Steam Input (not the game), the game doesn't see
> them as controller buttons — bind the *keys* you mapped them to, in-game. This is a
> known limitation; see the Gamepad Grimoire roadmap.

## 5. Controller cheat sheet in game

**[Gamepad Grimoire](https://github.com/sebastianstupak/gamepad-grimoire)** draws your
binds on a picture of *your* controller (front and back), lights up buttons as you
hold them, and lets you set everything up with the controller alone — no keyboard or
chat needed. It replaces the older DeckSetup addon. Install it like any other addon
(below).

## 6. Installing addons

WoW addons live in the AddOns folder inside the Proton prefix:

```
~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/drive_c/Program Files (x86)/World of Warcraft/<flavor>/Interface/AddOns/
```

Drop an addon's folder there with **WoW closed**, then enable it on the character
screen (**AddOns**). From your PC you can push one over SSH with the helper — it finds
the AddOns path automatically, refuses while WoW is running, and backs up any existing
copy on the Deck:

```sh
./install-addon.sh deck@<deck-ip> /path/to/MyAddon        # a folder
./install-addon.sh deck@<deck-ip> /path/to/MyAddon.zip    # or a packaged zip
```

For example, install Gamepad Grimoire by cloning it and pushing its addon folder.

## 7. (Optional) SSH for remote control

Enabling SSH on the Deck is handy for installing the watchdog, grabbing logs, or
automating. In Desktop Mode set a password (`passwd`), then
`sudo systemctl enable --now sshd`, and copy your key with `ssh-copy-id`.

## Repo layout

```
setup.sh             one-command remote install of the watchdog, over SSH
install-addon.sh     push a WoW addon to the Deck over SSH (with backup)
wow-guard/
  wow-guard.sh       the watchdog
  idle-watch.py      awake-idle reader for the background pre-warm
  wow-guard.service  the systemd --user unit
  install.sh         installs + enables the service (runs on the Deck)
```

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Blizzard or Valve.
