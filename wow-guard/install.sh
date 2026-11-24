#!/bin/bash
# (Re)install the WoW guard on the Steam Deck. Everything lives in ~/.local, so it
# survives SteamOS updates. Run on the Deck from this folder:
#   bash install.sh
# or push it from another machine over SSH:
#   scp wow-guard.sh wow-guard.service install.sh deck@<deck-ip>:/tmp/ && \
#   ssh deck@<deck-ip> 'bash /tmp/install.sh /tmp'
set -e
src=${1:-$(dirname "$0")}
mkdir -p ~/.local/bin ~/.config/systemd/user
sed 's/\r$//' "$src/wow-guard.sh" > ~/.local/bin/wow-guard.sh
chmod +x ~/.local/bin/wow-guard.sh
sed 's/\r$//' "$src/wow-guard.service" > ~/.config/systemd/user/wow-guard.service
bash -n ~/.local/bin/wow-guard.sh
systemctl --user daemon-reload
systemctl --user enable wow-guard.service >/dev/null
systemctl --user restart wow-guard.service
sleep 2
echo "wow-guard: $(systemctl --user is-active wow-guard) / $(systemctl --user is-enabled wow-guard)"
tail -n 3 ~/.local/state/wow-guard.log 2>/dev/null || true
