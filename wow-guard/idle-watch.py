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
        active = False
        for fd in r:
            try:
                while True:
                    data = os.read(fd, EVENT_SIZE)
                    if not data:          # EOF: device disconnected (e.g. a BT controller)
                        raise OSError("eof")
                    active = True
            except BlockingIOError:
                pass                      # drained all pending events (normal, O_NONBLOCK)
            except OSError:
                try:
                    os.close(fd)
                except OSError:
                    pass
                fds.remove(fd)            # drop the dead device so select() can't busy-spin on it
        if not fds:                       # every input device went away -> disable gracefully
            sys.stderr.write("idle-watch: all input devices closed\n")
            sys.exit(3)
        now = time.time()
        if active and now - last >= 1.0:  # debounce to ~1 write/sec
            stamp(); last = now

if __name__ == "__main__":
    main()
