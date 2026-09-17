# Claude Runway

macOS menu bar app (Swift, AppKit + SwiftUI) showing Claude Code's 5-hour and
weekly usage limits. No Xcode, no SPM, no third-party dependencies — Command Line
Tools only.

## Commands

```sh
./run-tests.sh            # compile Sources/RunwayCore + Tests/ into one binary and run it
./build.sh                # build arm64 app, ad-hoc sign, install to ~/Applications
./package.sh 1.2.3        # universal build → dist/ClaudeRunway-1.2.3.dmg
./logs.sh 10m             # unified log for the app
./tools/make-icon.sh      # regenerate Resources/AppIcon.icns
./tools/make-dmg-background.sh  # regenerate Resources/dmg-background.tiff
```

The app's own debug log is `~/Library/Application Support/ClaudeRunway/debug.log`
(`ok: session=NN% weekly_all=NN%` per fetch) — check it before guessing at a
data bug.

New test files must be added to the `swiftc` list in `run-tests.sh`.

## Layout

- `Sources/RunwayCore/` — logic, testable: fetching (`UsageController`,
  `WebUsageAPI`, `UsageAPI`), parsing, keychain, notifications, history, work log.
- `App/` — AppKit/SwiftUI shell (`main.swift` is the delegate), not compiled into tests.
- `Tests/` — custom harness (`T.test`, `T.equal`, `T.expect`).
- `tools/` — one-off helpers (icon, DMG background, probe, setkey).

## Things that are easy to get wrong

- **Percentages are always 0–100.** Never treat values ≤ 1 as a fraction: a
  fresh window's 1% would show as 100%.
- **Notifications** fire once each at 85%, 90%, 97% per bucket per reset window
  (`Notifier`). `resets_at` drifts between polls, so windows are matched with a
  30-minute tolerance, not by exact timestamp.
- **Keychain reads go through `/usr/bin/security`**, not `SecItemCopyMatching`.
  The app is ad-hoc signed, so its signature changes every release and a direct
  read would re-prompt for the login password after each update. The token is
  cached in memory until expiry. User-facing text must not talk about "tokens"
  being saved — say "Claude Code sign-in" instead.
- **Menu bar app has no visible menu**, so edit shortcuts (Cmd-V etc.) only work
  because `setUpEditMenu()` installs a hidden Edit menu. Keep it.
- **Distribution is a DMG** with the app at the top level plus an Applications
  symlink, so dragging replaces an existing install instead of adding a second
  copy. `package.sh` lays out the window by scripting Finder (needs a GUI
  session; works on GitHub macOS runners). On launch the app offers to trash
  other installed copies.
- Test fixtures are recorded API responses with past dates — don't add logic to
  the parser that depends on the current time.

## Releasing

Bump by semver (bug fixes → patch), then:

```sh
git tag v1.2.3 && git push origin v1.2.3
```

`.github/workflows/release.yml` runs tests, builds the universal DMG, verifies
it (arch, signature, Applications link, window layout), and publishes the GitHub
Release. Prefer a new version over moving an existing tag.

## Git conventions

- Commit as the GitHub noreply address already in git config; never use a work email.
- No `Co-Authored-By: Claude` trailer on commits.
