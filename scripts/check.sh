#!/bin/bash
# Portable build, localization and test gate. Does not launch the application.
set -euo pipefail
cd -P "$(dirname "$0")/.."
check_logs="$(mktemp -d "${TMPDIR:-/tmp}/camcord-check.XXXXXX")"
trap 'rm -rf -- "$check_logs"' EXIT
if ! swift build -Xswiftc -warnings-as-errors >"$check_logs/build.log" 2>&1; then
    cat "$check_logs/build.log"
    echo "CHECK: BUILD FAILED" >&2
    exit 1
fi
if grep -q 'warning:' "$check_logs/build.log"; then
    cat "$check_logs/build.log"
    echo "CHECK: BUILD WARNINGS" >&2
    exit 1
fi
# Package.swift emits localization data during compilation. The test suite checks
# live source ownership, complete English/Turkish values and catalog coverage.
if ! swift test -Xswiftc -warnings-as-errors >"$check_logs/test.log" 2>&1; then
    cat "$check_logs/test.log"
    echo "CHECK: TESTS FAILED" >&2
    exit 1
fi
if grep -q 'warning:' "$check_logs/test.log"; then
    cat "$check_logs/test.log"
    echo "CHECK: TEST WARNINGS" >&2
    exit 1
fi
check_summary="$(grep 'Test run with.*passed' "$check_logs/test.log" | tail -n 1 || true)"
if [[ -z "$check_summary" ]]; then
    cat "$check_logs/test.log"
    echo "CHECK: NO PASSING SWIFT TESTING SUMMARY" >&2
    exit 1
fi
printf 'CHECK: OK — build 0 warnings — %s\n' "$check_summary"
