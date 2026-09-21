# Peek

An AI assistant for macOS that appears where you're reading. Select text
anywhere, press a key, and ask about it — a floating panel opens next to the
pointer with the selection already supplied as context.

Native Swift throughout: SwiftUI, AppKit, Swift Concurrency, SwiftData,
ScreenCaptureKit, Keychain Services. No third-party runtime dependencies.

## Requirements

- macOS 26.0 or later
- Xcode 26.3+ / Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (build-time only, not shipped)

## Building

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Peek.xcodeproj -scheme Peek -configuration Debug build
```

Core tests run without building the app bundle:

```bash
cd Packages/PeekKit && swift test
```

App-layer tests (session, capture cascade, continuation policy):

```bash
xcodebuild test -project Peek.xcodeproj -scheme Peek -destination "platform=macOS"
```

Performance baseline — see [docs/performance.md](docs/performance.md):

```bash
PEEK_BENCHMARK=1 <built>/Peek.app/Contents/MacOS/Peek
```

## How it's invoked

Force Click **is** supported, but not through any public API — no public
mechanism exposes it, which
[ADR 0001](docs/adr/0001-force-click-cannot-be-detected-globally.md) establishes
by measurement. It works by reading raw trackpad pressure through a private
framework, resolved with `dlsym` so a future macOS disables the trigger rather
than the app. It is **off by default**.

| Trigger | Permission | Notes |
|---|---|---|
| `⌃⌥Space` global hotkey | none | `RegisterEventHotKey`; works on any input device |
| "Ask Peek" in the Services menu | none | macOS supplies the selection on the pasteboard |
| Menu bar item | none | Left click toggles, right click opens the menu |
| **Force Click** | Accessibility | Off by default; reads pressure via a private framework, see ADR 0001 |

## How context is captured

1. **Accessibility** (`kAXSelectedTextAttribute`) — instant, no side effects,
   and also yields the selection's on-screen bounds.
2. **Chromium/Gecko priming** — Electron apps expose nothing until
   `AXManualAccessibility` is set, then build their tree asynchronously, so
   Peek primes and retries once.
3. **Clipboard fallback** — a synthetic ⌘C sent to the source process with
   `postToPid`, with the pasteboard snapshotted and restored. Opt-out in
   settings, refused under Secure Input, and never used in password managers.

Peek never reads from a deny-listed app, and never from a secure text field.

## Architecture

```
Packages/PeekKit/          pure Swift, no AppKit — the testable core
  PeekCore                 stream events, request models, prompt composition,
                           capture policy, panel geometry, image budget,
                           force-click detection
  PeekProviders            provider protocol, SSE parsing, transport seam,
                           Gemini adapter, retry policy
  PeekPersistence          SwiftData conversation store behind a protocol
  PeekSecurity             Keychain credential storage, secret masking

App/Peek/                  AppKit + SwiftUI
  App/                     lifecycle, main menu, activation policy
  MenuBar/                 status item and activity indicator
  Panel/                   NSPanel subclass, placement, pre-warming
  Window/                  the expanded conversation window
  Triggers/                hotkey, Services provider
  Capture/                 Accessibility, clipboard, ScreenCaptureKit
  Settings/                preferences, login item
  Diagnostics/             benchmark harness
  Features/                SwiftUI views

Tests/PeekTests/           app-layer tests (session, capture cascade)
```

Two rules hold the design together:

**Nothing in `PeekKit` imports AppKit or SwiftUI.** That's what lets `swift test`
run the whole core in milliseconds without an app bundle, and it's enforced by
the module boundary rather than by discipline.

**Providers speak one normalised event vocabulary.** Each adapter translates its
own SSE dialect into `AssistantStreamEvent`; the UI, persistence layer and tests
know only that enum. Adapters are tested against recorded fixtures — including a
real captured Gemini stream — with no network.

## Privacy

- API keys live in the Keychain. Never in `UserDefaults`, never on disk in
  plain text, never in logs. Settings only ever displays a masked value.
- Selected text and screenshots go to the provider you configured and nowhere
  else. There is no telemetry.
- Diagnostics are redacted by construction: outcomes, byte counts, AX roles and
  token counts are logged; conversation content, selections and images are not.
- Conversations are stored unencrypted in
  `~/Library/Application Support/Peek/Conversations.store`. Deleting that file
  removes all history.
- On Google's free Gemini tier, prompts may be used to improve their products.
  Settings says so next to the key field.

## Keyboard

| Key | Action |
|---|---|
| `⌃⌥Space` | Show / hide the panel |
| `Esc` | Dismiss |
| `↩` | Send |
| `⌘N` | New conversation |
| `⌘K` | Conversation history |
| `⌘⇧O` | Expand into the window |
| `⌘.` | Stop streaming |
| `⌘,` | Settings |
| `⌘W` | Hide the panel |

## Distribution

Developer ID + hardened runtime + notarized, outside the Mac App Store. The
sandbox blocks cross-process Accessibility with no entitlement to lift it —
see [ADR 0002](docs/adr/0002-developer-id-not-app-store.md).

## Decision records

- [ADR 0001 — Force Click cannot be detected globally](docs/adr/0001-force-click-cannot-be-detected-globally.md)
- [ADR 0002 — Developer ID, not the App Store](docs/adr/0002-developer-id-not-app-store.md)
