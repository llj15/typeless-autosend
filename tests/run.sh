#!/bin/bash
# Build the binary into tests/.work and run every test_*.py. Needs the Xcode Command Line Tools and python3.
# The tests use dry-run mode, throw-away databases and a sandboxed HOME; they never touch the installed service.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf .work
mkdir -p .work

echo "==> Building"
swiftc -O ../*.swift -o .work/typeless-autoenter -lsqlite3

failed=0
for t in test_*.py; do
  echo "==> $t"
  python3 "$t" || failed=1
done

if [ "$failed" -eq 0 ]; then
  rm -rf .work
  echo "ALL SUITES PASSED"
else
  echo "SOME SUITES FAILED (logs are kept in tests/.work)" >&2
  exit 1
fi
