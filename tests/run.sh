#!/bin/bash
# Run every tests/test_*.sh; non-zero exit if any fails.
cd "$(dirname "$0")" || exit 2
rc=0
for t in test_*.sh; do
  echo "== $t =="
  bash "$t" || rc=1
done
exit $rc
