#!/usr/bin/env bash
# Install or update a WoW addon on the Steam Deck over SSH, from your PC.
# WoW must be CLOSED on the Deck; any existing copy is backed up there first.
#
#   ./install-addon.sh deck@<ip> /path/to/MyAddon          # an addon folder
#   ./install-addon.sh deck@<ip> /path/to/MyAddon.zip      # or a packaged zip
#   ./install-addon.sh deck@<ip> /path/to/MyAddon ~/.ssh/steamdeck
#
# The addon folder's name must match its .toc (standard WoW addon layout). The
# Deck's Battle.net appid and WoW AddOns folder are found automatically.
set -euo pipefail

host=${1:-}
src=${2:-}
key=${3:-}
if [ -z "$host" ] || [ -z "$src" ]; then
    echo "usage: $0 <user@deck-ip> <addon-folder-or-zip> [ssh-key]" >&2
    exit 1
fi
[ -e "$src" ] || { echo "not found: $src" >&2; exit 1; }

ssh_opts=(-o ConnectTimeout=10)
[ -n "$key" ] && ssh_opts+=(-i "$key")

name=$(basename "$src"); name=${name%.zip}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -d "$src" ]; then
    tar -C "$(dirname "$src")" -czf "$tmp/addon.tgz" "$(basename "$src")"
    kind=tgz
elif [ "${src##*.}" = zip ]; then
    cp "$src" "$tmp/addon.zip"; kind=zip
else
    echo "give an addon folder or a .zip" >&2; exit 1
fi

echo "==> copying $name to $host"
scp "${ssh_opts[@]}" "$tmp/addon.$kind" "$host:/tmp/gg-addon.$kind"

echo "==> installing on the Deck"
ssh "${ssh_opts[@]}" "$host" "KIND=$kind NAME=$(printf '%q' "$name") bash -s" <<'REMOTE'
set -e
appid=${BNET_APPID:-}
if [ -z "$appid" ]; then
    for d in "$HOME/.local/share/Steam/steamapps/compatdata"/*/; do
        [ -e "$d/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe" ] && { appid=$(basename "$d"); break; }
    done
fi
[ -n "$appid" ] || { echo "    no Battle.net prefix found - add Battle.net as a non-Steam game first"; exit 1; }
wowdir="$HOME/.local/share/Steam/steamapps/compatdata/$appid/pfx/drive_c/Program Files (x86)/World of Warcraft"
addons=""
for f in "$wowdir"/*/Interface/AddOns; do [ -d "$f" ] && { addons="$f"; break; }; done
[ -n "$addons" ] || { echo "    no WoW Interface/AddOns folder found"; exit 1; }
pgrep -x Wow.exe >/dev/null && { echo "    WoW is running - close it first"; exit 1; }
if [ -d "$addons/$NAME" ]; then
    bak="$HOME/wow-backups/addons/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$bak"
    mv "$addons/$NAME" "$bak/"; echo "    backed up old $NAME to $bak"
fi
cd "$addons"
if [ "$KIND" = tgz ]; then
    tar -xzf /tmp/gg-addon.tgz
else
    command -v unzip >/dev/null || { echo "    unzip not available; push a folder instead of a .zip"; exit 1; }
    unzip -oq /tmp/gg-addon.zip
fi
rm -f /tmp/gg-addon.tgz /tmp/gg-addon.zip
[ -d "$addons/$NAME" ] && echo "    installed $NAME" || echo "    extracted (the zip's top folder may differ from '$NAME' - check $addons)"
REMOTE
echo "==> done. New addons load after a /reload or a restart; enable them on the character screen (AddOns)."
