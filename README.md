# Claude Runway

**Claude Code usage limits in your macOS menu bar.**

Claude Code's 5-hour and weekly limits are invisible until you hit them. Claude
Runway keeps them in the menu bar, so you know whether you have the headroom to
start something long *before* you start it.

The menu bar item is a spark and your 5-hour percentage — about 44pt wide. The
spark takes the risk colour; the number stays neutral, so exactly one thing ever
changes appearance. Click it for every limit your plan has, reset countdowns, a
24-hour sparkline, and a log of what you actually did today.

Requires **macOS 14+** and **Claude Code, installed and signed in**.

---

## Contents

- [Why it exists](#why-it-exists)
- [Install](#install)
- [Getting a session key](#getting-a-session-key)
- [How it gets data](#how-it-gets-data)
- [The Work tab](#the-work-tab)
- [Design notes](#design-notes)
- [Security and credential handling](#security-and-credential-handling)
- [Development](#development)
- [Trademark, affiliation, and scope](#trademark-affiliation-and-scope)
- [License](#license)

---

## Why it exists

A raw percentage is a bad answer to "can I start this?". 60% used is alarming an
hour into a five-hour window and unremarkable four hours in, because the window
is about to reset. So this app doesn't just report a number — it reports whether
you are **outrunning the window**, which is the thing you actually need to know.

The weekly limit isn't shown in the menu bar by choice. It's in the tooltip and
the popover, and the 90% notification fires for it like any other limit.

## Install

```sh
git clone https://github.com/Shaheer-Arshad/ClaudeRunway.git
cd ClaudeRunway
./build.sh              # builds and installs to ~/Applications
open ~/Applications/ClaudeRunway.app
```

Builds with **Command Line Tools only — no Xcode needed**. If `swiftc` is
missing, run `xcode-select --install`.

It's an `LSUIElement` app, so it has no Dock icon. To launch it after quitting,
find "Claude Runway" in Spotlight or `~/Applications`, or drag it to your Dock.
The popover's **Launch at login** toggle avoids the question entirely.

### Sharing a build

```sh
./package.sh            # → dist/ClaudeRunway-1.0.zip
```

The app is ad-hoc signed, so Gatekeeper blocks the first launch on another Mac
(`spctl` reports `rejected` — verified, not assumed). The recipient right-clicks
→ **Open** once, or uses System Settings → Privacy & Security → **Open Anyway**.
Removing that friction requires a paid Apple Developer account and notarisation.
See [the ad-hoc signing limitation](#known-limitation-ad-hoc-signing).

## Getting a session key

The app works with **no configuration at all** — it falls back to the OAuth token
Claude Code already stored when you signed in. But that path is slow (a 15-minute
poll), so if you want 60-second updates, give it a session key.

1. Open <https://claude.ai> in your browser and make sure you're logged in.
2. Open DevTools (`⌥⌘I` in Chrome/Edge, `⌥⌘C` in Safari with the develop menu on).
3. Go to **Application** → **Storage** → **Cookies** → `https://claude.ai`.
4. Find the row named **`sessionKey`** and copy its **Value**.
5. Click the menu bar item and paste it into the **Add a session key** field.

Paste the bare value, `sessionKey=…`, or the whole cookie header — all three are
accepted and normalised. A value that doesn't start with `sk-ant-sid` is rejected
before any network request, so a mis-copy fails fast instead of confusingly.

You never need to look up your organization ID; it's derived from the key.

> **This key is a bearer credential for your entire Claude account** — not just
> usage data. Treat it like a password. It's stored in your login keychain and
> sent only to `claude.ai`. If you ever paste it somewhere it shouldn't go, log
> out of claude.ai and back in; that invalidates it immediately.

Session keys expire. When that happens the app says so, prompts for a new one,
and falls back to the slow path meanwhile — it does not break.

## How it gets data

Two transports. The app uses whichever is available, preferring the fast one.

### 1. Live (preferred) — claude.ai session key

Polls `GET https://claude.ai/api/organizations/{org}/usage`, the endpoint the
claude.ai web UI itself uses. **Effectively unthrottled** — five requests two
seconds apart all returned 200 — so the app polls every **60 seconds**.

This endpoint sits behind Cloudflare. Native `URLSession` passes the challenge
because its TLS fingerprint resembles Safari's; `curl` is blocked. That
difference is the entire reason this route is viable.

### 2. Fallback — Claude Code's OAuth token

With no session key, the app reads the OAuth token Claude Code already stores in
your keychain (`Claude Code-credentials`) and calls
`GET https://api.anthropic.com/api/oauth/usage` — the endpoint behind `/usage`.

Nothing to configure, but it is **heavily rate limited**:

| Gap since previous request | Result |
|---|---|
| ~75s | 429 |
| ~5 min | 429 |
| ~6–7 min | 200 |

Roughly one request per 6–7 minutes, and that quota is *shared with Claude Code
itself*. So this path enforces a 10-minute floor and polls every 15 minutes.

The app only ever **reads** that token; it never refreshes it, since rotating it
could break a running Claude Code session. It does check the stored `expiresAt`
before sending, so an expired token costs an error message rather than a request
out of a quota you need.

### Cadence summary

| Transport | Poll | Floor between requests |
|---|---|---|
| Live (session key) | 60s | 15s |
| OAuth fallback | 15 min | 10 min |

Backoff after a 429 is 5 → 10 → 20 → 40 → 60 min, tracked **per transport** — the
two endpoints have separate quotas, so one being throttled must not penalise the
other. Both the floor and the backoff are persisted, so quitting and relaunching
cannot bypass them. The Refresh button in the popover is the only override.

## The Work tab

The popover has two tabs. **Usage** is everything above. **Work** answers the
other end-of-day question: what did I actually do?

It reads the session transcripts Claude Code already writes to
`~/.claude/projects/`, and groups the day by the repo each session ran in:

```
skuscraper
  • Build WePlayHandball crawler for Germany
agent-accounts-support
  • Apply PR 200 fix to accounts agent
      – Port ChromaHealthService + container wiring
      – Port /health/chroma-reachability endpoint
```

Every line was written by Claude Code as it worked — the bullet is the session's
own `ai-title`, the sub-bullets are todos it marked completed. **No model is
called to produce any of it**, so opening the tab costs nothing against the
limits the rest of the app is watching.

Arrows step back a day at a time. **Copy** puts the visible day on the clipboard
as markdown, for a standup note or a timesheet. The view is read-only. Sessions
run from `~/Desktop` or `~` rather than a project are labelled `Desktop (no repo)`
rather than dressed up as one.

Transcripts are parsed once and cached in Application Support against each file's
size and mtime, so only sessions that actually changed are re-read — a cold scan
of ~80 transcripts takes under two seconds, a warm one milliseconds.

## Design notes

The popover answers one question: *do I have headroom to start something long?*

The gauge shows two things at once:

- the **arc** is how much you've used
- the **notch** is where even consumption would put you right now

The gap between them is the reading. Arc past notch means you're outrunning the
window. `RiskModel.swift` turns that into a 0–1 risk from the worst of three
signals — absolute level, projected end-of-window usage, and pacing delta — with
early-window projections damped until there's enough evidence to trust them.

Colour is split deliberately. The indigo accent is chrome — the mark, the
sparkline — and never changes. The risk ramp (green → amber → red, interpolated
in HSB so midpoints don't go muddy) is the *only* thing that changes colour, so
any colour change means exactly one thing: your headroom moved. The accent is
cool precisely so it can never be misread as a step on that warm ramp. The menu
bar stays monochrome below the first ramp stop, because colour up there should
mean "look at me", not "everything is fine".

Both surfaces call the same `RiskModel`, so they cannot disagree.

## Security and credential handling

This app touches two bearer credentials for your whole Claude account: the
claude.ai session key and Claude Code's OAuth token. Both live in the login
keychain and are read, never copied to disk anywhere else.

- Requests go through a dedicated **ephemeral** `URLSession` (`UsageTransport`) —
  no on-disk response cache, no persistent cookie jar, no credential storage.
- **Redirects are refused.** `URLSession` strips a manually set `Authorization`
  header across origins but copies every *other* header, including a hand-built
  `Cookie`. Neither endpoint has any business redirecting, so the session
  delegate returns `nil` rather than forward a credential to a host we didn't
  choose.
- The organization ID is **validated as a UUID** before it is cached or
  interpolated into a URL. It arrives from the network and is cached in
  `UserDefaults`, which is a plain user-writable plist — neither is a source to
  paste into a request path unchecked.
- The OAuth token's `expiresAt` is checked locally, so an expired credential
  never costs a request from a shared quota.
- Neither credential is ever logged, printed, or included in an error message.
  The debug log records transports and outcomes, never secrets.
- `./tools/setkey` reads the key from **stdin**, not an argument or environment
  variable, so it never lands in shell history or shows up in `ps -E`.

Nothing is sent anywhere except `claude.ai` and `api.anthropic.com`. There is no
telemetry, no analytics, and no third-party dependency of any kind — the app is
Foundation, AppKit and SwiftUI only.

### Known limitation: ad-hoc signing

`build.sh` signs the bundle ad-hoc (`codesign --sign -`) with a stable
identifier, because that's what Command Line Tools alone can do. An ad-hoc
signature has no Team ID and no notarisation, so the code identity is
effectively just the string `com.shaheer.clauderunway`. Two consequences:

- Once you grant **Always Allow** for the `Claude Code-credentials` keychain
  item, any locally built binary that ad-hoc-signs itself with the same
  identifier inherits that grant.
- There is no hardened runtime, so nothing prevents another process running as
  you from attaching to the app and reading the token out of memory.

Fixing this properly needs a Developer ID identity and `codesign --options
runtime`; the same identity is what would let the keychain items move to the
data-protection keychain. For a personal build on your own machine this is
acceptable. For anything redistributed, it isn't.

**Found a security issue?** Please open an issue, or contact the maintainer
privately if it's sensitive.

## Development

```sh
./run-tests.sh        # 169 assertions, no XCTest required
./tools/probe.sh      # raw OAuth response — mind the rate limit
./tools/render.sh     # menu bar item across usage states, both appearances
./tools/make-icon.sh  # regenerate Resources/AppIcon.icns after changing the mark
tail -f ~/Library/Application\ Support/ClaudeRunway/debug.log
```

### Layout

```
Sources/RunwayCore/        platform-independent: keychain, transports, parsing, scheduling
  Keychain.swift             reads Claude Code's OAuth token (read-only, by design)
  SessionKeyStore.swift      stores the claude.ai session key
  UsageTransport.swift       the hardened URLSession both transports share
  WebUsageAPI.swift          live transport
  UsageAPI.swift             OAuth fallback transport
  UsageParser.swift          shared — both endpoints return identical JSON
  RefreshGate.swift          transport choice + request spacing (pure, tested)
  RiskModel.swift            usage + pacing → a single 0–1 risk
  HistoryStore.swift         rolling sample history behind the sparkline
  WorkLogParser.swift        transcript → one session's title and todos
  WorkLogStore.swift         scans ~/.claude/projects, caches by size+mtime
App/                       AppKit + SwiftUI: menu bar, popover, watchers
Tests/                     assertions, compiled into the same module
tools/                     probe, setkey, render, make-icon
```

`Sources/` has no AppKit dependency, so parsing and scheduling are testable
without a UI.

`render.sh` writes PNGs of the menu bar item at 0/12/71/94/100% and the no-data
state, in light and dark. A menu bar item is awkward to screenshot and some of
those states take hours to reach naturally, so this is how they get checked.

A menu bar app has no stdout, so the debug log is how you see what it's doing.
It records every fetch, its transport (`live` / `slow mode`), and why a fetch was
skipped — a throttled app otherwise looks identical to a broken one.

### Not implemented

- **Context-window usage.** Only available via Claude Code's statusline push
  (`context_window.used_percentage`), which requires adding a `statusLine` entry
  to `~/.claude/settings.json`. Deferred rather than modify your Claude Code
  config — the live transport made it unnecessary for speed.

## Trademark, affiliation, and scope

**This is an unofficial, independent project. It is not affiliated with,
endorsed by, sponsored by, or connected to Anthropic in any way.**

"Claude", "Claude Code" and "Anthropic" are trademarks of Anthropic PBC. They are
used here only to identify the product this tool works with — nominative use —
not to suggest any endorsement or origin. The app's own mark is a four-point
spark drawn programmatically in `App/SparkMark.swift`; it is not, and is not
intended to resemble, any Anthropic mark, and none of Anthropic's brand assets or
brand colours are used or bundled.

**Both endpoints are undocumented and unsupported.** They may change or disappear
without notice, and using them is at your own risk. Check Anthropic's Terms of
Service and make your own decision about whether this fits them; nothing here is
legal advice. This project reads only your own usage data using your own
credentials — it does not circumvent, extend, or alter any limit.

If you're at Anthropic and would like something here changed, please open an
issue; I'll act on it.

## License

[MIT](LICENSE) © Shaheer-Arshad

The MIT grant covers this project's own source. It does not grant any rights in
Anthropic's trademarks or brand assets.
