#!/bin/bash
# Tail the app's own log output. Handy because a menu bar app has no stdout.
exec log show --last "${1:-5m}" --info --debug \
  --predicate 'subsystem == "com.shaheer.clauderunway"' --style compact
