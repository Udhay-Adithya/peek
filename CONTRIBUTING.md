# Contributing to Peek

## Getting set up

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Peek.xcodeproj -scheme Peek -configuration Debug build
```

`Peek.xcodeproj` is generated and not tracked. `project.yml` is the source of
truth — edit that, then re-run `xcodegen generate`. Adding a file means
regenerating the project before it will build.

Requires macOS 26 and Xcode 26.3 or later.

## Running the tests

```bash
cd Packages/PeekKit && swift test                                             # core, ~1s
xcodebuild test -project Peek.xcodeproj -scheme Peek -destination "platform=macOS"  # app layer
```

Both run in CI on every pull request.

## Where code belongs

**`Packages/PeekKit` is the testable core and must never import AppKit or
SwiftUI.** That boundary is what lets the core suite run in milliseconds without
an app bundle, and it is enforced by the module graph rather than by convention.
Anything that needs a window, an event, a screen or a permission lives in
`App/Peek`.

When something in the app layer resists testing, the usual answer is that a
decision is tangled up with a platform call. Pull the decision into `PeekKit` as
a pure function or state machine and leave the platform call behind a protocol —
`ForceClickDetector`, `PanelPlacement` and `CapturePolicy` all came out of that.

## Testing expectations

- Test behaviour, not implementation. A test that breaks on every refactor is
  worse than no test.
- **Prefer recorded real data to hand-written fixtures.** Peek's SSE parser had
  ten passing tests while the feature was completely broken, because every
  fixture matched what the author *assumed* the wire format looked like. The
  regression fixture is now a real captured Gemini stream.
- Provider adapters are tested against fixtures with no network. If a test needs
  the internet, it is in the wrong place.
- SwiftData suites are nested under one `.serialized` parent — creating several
  `ModelContainer`s concurrently crashes inside the framework.

## Style

- Comments explain *why*, not *what*. If a line is surprising, say what it would
  break otherwise.
- Small focused types; protocols where they buy testability or a real seam, not
  as decoration.
- Swift 6 strict concurrency is on. Actor isolation problems are usually a real
  design issue, not a compiler annoyance.
- No new third-party runtime dependencies without a clear justification. Peek
  ships exactly one (Sparkle), and it is argued for in the code.

## Commits

Conventional commits, all lower case:

```
feat(capture): add vision ocr fallback for unsupported apps
fix(panel): keep the placement on-screen for negative display origins
docs(adr): record why force click needs a private framework
```

Scopes in use: `core`, `providers`, `persistence`, `security`, `capture`,
`panel`, `triggers`, `settings`, `updates`, `ui`, `app`, `build`, `docs`,
`test`, `perf`, `spike`.

## Changelog

Every user-visible change needs an entry under `## [Unreleased]` in
[CHANGELOG.md](CHANGELOG.md), following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/): `Added`, `Changed`,
`Deprecated`, `Removed`, `Fixed`, `Security`.

Write for someone deciding whether to update, not for someone reading the diff.
Internal refactors, test changes and CI tweaks do not need an entry.

A merged feature is released — see [docs/releasing.md](docs/releasing.md).
Peek has no other distribution channel, so a feature sitting unreleased on
`main` is a feature nobody has.

## Pull requests

One concern per pull request. Include what you actually verified — "builds and
tests pass" is not the same as "I used it", and for this app the difference has
mattered repeatedly.

If you found a limitation in an Apple API, write it down. Peek's
[decision records](docs/adr/) exist because several of this project's hardest
questions have answers that are only obvious once someone has measured them.
