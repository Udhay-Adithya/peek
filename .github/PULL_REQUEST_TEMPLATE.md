<!--
One concern per pull request. If this is a work in progress, open it as a draft.
-->

## What this changes

<!-- What behaviour is different afterwards, and why. Not a summary of the diff. -->

Closes #

## How it was verified

<!--
Be specific, and separate what you ran from what you actually used. Builds and
green tests are necessary, not sufficient — most real bugs in this project were
found by using the app, not by the suite.
-->

- [ ] `cd Packages/PeekKit && swift test`
- [ ] `xcodebuild test -project Peek.xcodeproj -scheme Peek -destination "platform=macOS"`
- [ ] Used the built app and exercised the change by hand

Apps or conditions tried:

<!--
Coverage varies sharply by app family and this is where surprises live:
native AppKit (Notes, TextEdit), Electron (Obsidian, VS Code), Gecko (Firefox,
Zen), terminals (Ghostty), and multi-display or scaled setups.
-->

## Checklist

- [ ] `CHANGELOG.md` updated under `## [Unreleased]`, or not user-visible
- [ ] No new third-party runtime dependency, or justified in the PR and in code
- [ ] `PeekKit` still imports no AppKit or SwiftUI
- [ ] No secrets, keys or personal identifiers added
- [ ] New permissions, if any, are requested at the point of use and degrade
      gracefully when refused

## Anything you are unsure about

<!--
Genuinely useful. Undocumented API behaviour, a threshold picked by measurement,
a race you suspect but could not reproduce — say so here rather than leaving it
for the reviewer to find.
-->
