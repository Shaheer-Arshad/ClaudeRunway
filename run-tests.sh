#!/bin/bash
# Compiles the core sources together with the test files into one throwaway
# binary and runs it. No SPM/XCTest: Command Line Tools ships neither.
set -euo pipefail
cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O \
  Sources/RunwayCore/*.swift \
  Tests/TestHarness.swift \
  Tests/WorkLogTests.swift \
  Tests/HistoryTests.swift \
  Tests/CredentialTests.swift \
  Tests/main.swift \
  -o "$OUT/tests"

"$OUT/tests"
