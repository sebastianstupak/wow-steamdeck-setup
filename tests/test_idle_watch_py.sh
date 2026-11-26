#!/bin/bash
# Runnable check of idle-watch.py WITHOUT real /dev/input hardware (portable, no hang):
# import the module (which does not call main() because __name__ != "__main__"), then
#  1) call stamp() and confirm it atomically writes a current epoch, and
#  2) monkeypatch open_readable() to [] and confirm main() exits non-zero (3) -- the
#     exact fallback the watchdog relies on to disable the awake-idle layer.
cd "$(dirname "$0")" || exit 2
if ! command -v python3 >/dev/null 2>&1; then echo "  skip: python3 not found"; echo "ALL PASS"; exit 0; fi

tmp=$(mktemp -d)
python3 - "$tmp/stamp" <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("iw", "../wow-guard/idle-watch.py")
iw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iw)                 # sets iw.STAMP from argv[1]; defines funcs; no main()
iw.stamp()                                  # 1) atomic seed
v = int(open(iw.STAMP).read())
assert abs(v - int(time.time())) <= 5, "stamp epoch off: %s" % v
iw.open_readable = lambda: []               # 2) no readable devices -> graceful exit
try:
    iw.main()
except SystemExit as e:
    assert e.code == 3, "expected exit 3, got %s" % e.code
else:
    raise AssertionError("main() did not exit when no input devices were readable")

# 3) a device that EOFs (disconnected, e.g. a BT controller) is dropped, not spun on;
#    if it was the only device, main() exits 3 instead of busy-looping.
FAKE = 99999
iw.open_readable = lambda: [FAKE]
_scount = {"n": 0}
def _fakeselect(rl, wl, xl, t):
    _scount["n"] += 1
    if _scount["n"] > 5:                     # fix works in 1 iteration; >5 == busy-spin regression
        raise AssertionError("main() kept looping after device EOF (busy-spin regression)")
    return (list(rl), [], [])
_realread, _realclose = iw.os.read, iw.os.close
iw.select.select = _fakeselect
iw.os.close = lambda fd: None
iw.os.read = lambda fd, n: b"" if fd == FAKE else _realread(fd, n)  # FAKE EOFs immediately
try:
    iw.main()
except SystemExit as e:
    assert e.code == 3, "expected exit 3 after the only device EOF'd, got %s" % e.code
else:
    raise AssertionError("main() did not exit when its only device disconnected")
iw.os.read, iw.os.close = _realread, _realclose
print("PYOK")
PY
rc=$?
rm -rf "$tmp"
[ "$rc" -eq 0 ] && echo "  ok: idle-watch.py seed + no-device exit(3)" || { echo "  FAIL: idle-watch.py checks (rc=$rc)"; exit 1; }
echo "ALL PASS"
