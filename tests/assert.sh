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
