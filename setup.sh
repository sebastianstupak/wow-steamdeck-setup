#!/usr/bin/env bash
# One-shot remote setup: from your computer, install the wow-guard watchdog on the
# Steam Deck over SSH. (Enable SSH on the Deck first - see the README.)
#
#   ./setup.sh deck@192.168.1.104              # uses your default SSH key / agent
#   ./setup.sh deck@192.168.1.104 ~/.ssh/steamdeck
#
# Idempotent: re-run it any time to update the watchdog.
set -euo pipefail

host=${1:-}
key=${2:-}
if [ -z "$host" ]; then
    echo "usage: $0 <user@deck-ip> [ssh-key]" >&2
    exit 1
fi

ssh_opts=(-o ConnectTimeout=10)
[ -n "$key" ] && ssh_opts+=(-i "$key")

dir=$(cd "$(dirname "$0")" && pwd)/wow-guard

echo "==> checking connection to $host"
ssh "${ssh_opts[@]}" "$host" 'echo "    connected: $(uname -sr)"'

echo "==> copying wow-guard to $host:/tmp"
scp "${ssh_opts[@]}" "$dir/wow-guard.sh" "$dir/wow-guard.service" "$dir/install.sh" "$host:/tmp/"

echo "==> installing and starting the service"
ssh "${ssh_opts[@]}" "$host" 'bash /tmp/install.sh /tmp && rm -f /tmp/wow-guard.sh /tmp/wow-guard.service /tmp/install.sh'

echo "==> done. Tail the log with:"
echo "    ssh ${key:+-i $key }$host 'tail -f ~/.local/state/wow-guard.log'"
