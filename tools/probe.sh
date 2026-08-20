#!/bin/bash
# Diagnostic: print the raw /api/oauth/usage response.
#
# Use sparingly. The endpoint tolerates roughly one request per 6-7 minutes and
# shares that quota with Claude Code itself, so probing in a loop will 429 both
# this tool and the app.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O Sources/RunwayCore/Keychain.swift tools/probe/main.swift -o "$OUT/probe"
"$OUT/probe"
