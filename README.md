# Peek

**A better Look Up for macOS.**

Force Click a word on macOS and you get a dictionary definition, a Wikipedia
stub and a handful of data detectors. The gesture is in exactly the right place —
it is the moment you stop and wonder about something — and it answers almost
nothing you actually wanted to know.

Peek takes that moment and answers properly. Select anything, invoke it, and a
panel opens beside the pointer with your selection already in context. Ask what
it means, what the code does, how to say it in another language, what the error
is telling you. Then ask a follow-up, because unlike Look Up this is a
conversation.

It runs on Apple Intelligence **on your Mac by default** — no API key, nothing
leaves the machine — and can use a cloud provider when you want a larger model.

## How it compares

| | macOS Look Up | Peek |
|---|---|---|
| Answers | dictionary, thesaurus, a few detectors | anything you can ask |
| Follow-ups | none | a full conversation |
| Works in | apps that expose text to the system | the same, plus a clipboard fallback for Electron and Firefox-based apps |
| Changes your text | no | fix grammar, improve writing, make it shorter |
| Screenshots | no | attach a region or the whole screen |
| History | none | searchable and persistent |
| Invoked by | Force Click | Force Click, a global shortcut, the Services menu, or the menu bar |

## Install

Download the latest notarized DMG from
[Releases](https://github.com/Udhay-Adithya/peek/releases/latest) and drag Peek
to Applications. It updates itself from there.

Peek lives in the menu bar and stays out of the way. Requires macOS 26 or later.

### Turning on the menu entries

macOS ships third-party Services **disabled by default**, so "Ask Peek" and the
rewrite options will not appear in the right-click menu until you switch them
on — once:

> System Settings → Keyboard → Keyboard Shortcuts → **Services** → Text, and
> tick Peek's four entries.

Apps that were already open need relaunching to pick them up. Peek's Settings
shows whether this is done and links straight there.

### Replacing Look Up

Peek can use the same Force Click gesture Look Up uses. Turn Peek's Force Click
trigger on in Settings, then switch the system's own off in
**System Settings → Trackpad → Point & Click → Look up & data detectors → Off**,
or both will open at once. macOS exposes no way for an app to do this for you.

Prefer to keep Look Up? Leave Force Click off and use `⌃⌥Space`.

## How it works

### Invoking it

| Trigger | Permission | Notes |
|---|---|---|
| `⌃⌥Space` | none | Works on any Mac, with any input device |
| "Ask Peek" in the Services menu | none | Appears in most apps; bindable to your own shortcut |
| "… with Peek" in the Services menu | Accessibility to write back | Rewrites the selection in place, after showing you the result |
| Menu bar | none | Left click opens, right click for the menu |
| **Force Click** | Accessibility | Off by default — see [ADR 0001](docs/adr/0001-force-click-cannot-be-detected-globally.md) |

Force Click is not reachable through any public macOS API, which
[ADR 0001](docs/adr/0001-force-click-cannot-be-detected-globally.md) establishes
by measurement rather than assertion. Peek reads raw trackpad pressure through a
private framework, resolved at runtime so that a future macOS release disables
the trigger rather than the app.

### Reading your selection

1. **Accessibility** — instant, no side effects, and it yields the selection's
   on-screen position.
2. **Chromium and Gecko priming** — Electron apps expose nothing until asked,
   then build their accessibility tree asynchronously, so Peek primes and
   retries.
3. **Clipboard fallback** — a synthetic copy sent to the source app, with your
   clipboard snapshotted and restored afterwards. Optional, and never used in
   password managers.

Peek never reads from a deny-listed app, and never from a secure text field.

## Privacy

- **On-device by default.** Apple Intelligence runs locally; nothing is sent
  anywhere unless you choose a cloud provider.
- **API keys live in the Keychain** — never in preferences, never on disk in
  plain text, never in logs. Settings only ever shows a masked value.
- **No telemetry.** Selected text and screenshots go to the provider you
  configured and nowhere else.
- **Diagnostics are redacted by construction** — outcomes, byte counts and
  accessibility roles are recorded; conversation content, selections and images
  are not.
- Conversations are stored unencrypted at
  `~/Library/Application Support/Peek/Conversations.store`. Deleting that file
  removes all history.
- On Google's free Gemini tier, prompts may be used to improve their products.
  Settings says so beside the key field.

## Keyboard

| Key | Action |
|---|---|
| `⌃⌥Space` | Show / hide the panel |
| `Esc` | Dismiss |
| `↩` | Send |
| `⇧↩` | New line |
| `⌘N` | New conversation |
| `⌘K` | Conversation history |
| `⌘⇧O` | Open in the main window |
| `⌘.` | Stop streaming |
| `⌘,` | Settings |
| `⌘Q` | Hide to the menu bar |

## Building

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Peek.xcodeproj -scheme Peek -configuration Debug build
```

Requires macOS 26 and Xcode 26.3 or later.

Core tests run in seconds, without building an app bundle:

```bash
cd Packages/PeekKit && swift test
```

App-layer tests:

```bash
xcodebuild test -project Peek.xcodeproj -scheme Peek -destination "platform=macOS"
```

## Architecture

```
Packages/PeekKit/          pure Swift, no AppKit — the testable core
  PeekCore                 stream events, request models, prompt composition,
                           capture policy, panel geometry, image budget,
                           force-click detection
  PeekProviders            provider protocol, SSE parsing, transport seam,
                           Gemini and Apple Intelligence adapters, retry policy
  PeekPersistence          SwiftData conversation store behind a protocol
  PeekSecurity             Keychain credential storage, secret masking

App/Peek/                  AppKit + SwiftUI
  App/                     lifecycle, main menu, activation policy
  MenuBar/                 status item and activity indicator
  Panel/                   NSPanel subclass, placement, pre-warming
  Window/                  the expanded conversation window
  Triggers/                hotkey, Services provider, Force Click
  Capture/                 Accessibility, clipboard, ScreenCaptureKit
  Settings/                preferences, login item
  Updates/                 Sparkle integration
  Diagnostics/             benchmark harness
  Features/                SwiftUI views

Tests/PeekTests/           app-layer tests
```

Two rules hold the design together. **Nothing in `PeekKit` imports AppKit or
SwiftUI**, which is what lets the core suite run in milliseconds without an app
bundle — enforced by the module boundary rather than by discipline. And **every
provider speaks one normalised event vocabulary**, so the UI, persistence layer
and tests never learn a vendor's wire format. Adapters are tested against
recorded fixtures, including a real captured Gemini stream.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes are recorded in
[CHANGELOG.md](CHANGELOG.md), following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Decision records

- [ADR 0001 — Force Click cannot be detected globally](docs/adr/0001-force-click-cannot-be-detected-globally.md)
- [ADR 0002 — Developer ID, not the App Store](docs/adr/0002-developer-id-not-app-store.md)
- [Performance baseline](docs/performance.md)
