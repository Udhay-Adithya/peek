# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-10-12

### Added

- **Control Center control.** Peek can be opened from Control Center, or pinned
  to the menu-bar clock, for when neither a shortcut nor the menu bar is to
  hand.
- **A `peek://` URL scheme** — `peek://show`, `peek://conversations` and
  `peek://settings` open the corresponding surface. This is how the control
  reaches the app, and it works from a script or `open` as well. It only ever
  opens something; nothing can be sent through it.

## [0.5.0] - 2026-10-12

### Added

- **Find past conversations in Spotlight.** Answers you got weeks ago are now
  searchable with ⌘Space, and opening a result brings that conversation up in
  Peek. The text you asked *about* is indexed alongside what you typed, so
  searching for the phrase you looked up works as well as searching for your
  question.
- A Spotlight setting to turn this off. Doing so removes everything Peek has
  added to the index, rather than merely stopping new additions.

### Security

- Screenshots are never indexed — only a count of them. The text of a
  conversation goes into the local, account-protected system index; the image
  bytes do not.

## [0.4.1] - 2026-10-12

### Fixed

- **Replace now works.** Rewriting a selection writes the result back into the
  app you were using, rather than appearing to succeed and changing nothing.
  Peek was writing while the source app was in the background, where a paste is
  ignored and the text attribute is often read-only; the app is now brought
  forward first. The 0.3.0 workaround of copying the result by hand is no
  longer needed.
- Diagnostics for write failures are now recorded at a level the system keeps,
  so a future problem here can be diagnosed from the log instead of guessed at.

## [0.4.0] - 2026-10-12

### Added

- **Shortcuts, Spotlight and Siri support.** *Ask Peek* is now an action you can
  use in Shortcuts, run from Spotlight, or say to Siri. It takes a question and
  returns the answer as text, so it can feed the next step of a shortcut rather
  than just opening a window.
- *Show Peek* opens the floating panel from a shortcut — useful as the last
  step of an automation that has gathered context and wants you to take over.
- Questions asked this way are saved to your history like any other
  conversation, labelled as coming from Shortcuts.

## [0.3.0] - 2026-10-09

### Added

- **Rewrite your text.** Peek can now change your writing, not just answer
  questions about it. Select anything and choose **Fix Spelling & Grammar**,
  **Improve Writing** or **Make Shorter** from the Services menu, and Peek
  shows you its version alongside your own.

  **Known limitation:** writing the result back into the source app does not
  work reliably yet, so use **Copy** and paste it yourself for now. Your
  original text is never modified without you pressing Replace, and is always
  recoverable from the panel. Tracked in
  [#13](https://github.com/Udhay-Adithya/peek/issues/13).
- The proposal streams in as it is written, so a long passage shows progress
  rather than sitting blank, and you can switch to a different rewrite without
  starting over.
- Your original text is kept for the whole session and can be copied back to
  the clipboard at any point.
- Settings now reports whether Peek's Services menu entries are switched on.
  macOS disables third-party services by default and says nothing about it, so
  the menu items appear missing until you tick them — Settings now says so and
  links to the right place.

### Security

- Rewriting refuses to write into password managers and secure text fields,
  under the same deny-list that governs reading.
- The rewrite prompt treats your selection strictly as text to transform, so
  instructions embedded in a document are rewritten rather than followed.

## [0.2.0] - 2026-09-28

### Added

- **Read text from the screen.** When an app exposes no selection — PDFs,
  images, video frames, canvas-drawn apps, remote desktops — Peek now offers to
  read it from the screen instead. Drag over the part you mean and the text is
  recognised locally with Vision. Nothing leaves your Mac, and it needs no
  permission beyond the Screen Recording grant screenshots already use.
- Context captured this way is labelled **read from screen** in the panel, so
  it is clear whether you are looking at the app's own text or Peek's reading
  of the pixels.

### Changed

- Apps that share no selected text now offer this as an action instead of
  stating the problem and stopping.

## [0.1.0] - 2026-09-28

First release.

### Added

- **Floating assistant panel** that opens beside the pointer with the current
  selection already supplied as context, and expands into a full window.
- **Four ways to invoke it**: a global `⌃⌥Space` shortcut, an "Ask Peek" entry
  in the Services menu, the menu bar item, and Force Click.
- **Force Click trigger**, off by default, reading raw trackpad pressure. No
  public macOS API exposes Force Click; the detection thresholds were derived
  from measurement on real hardware.
- **Selected-text capture** through the Accessibility API, with Chromium and
  Gecko priming for Electron and Firefox-based apps, and an optional clipboard
  fallback for apps that expose no selection at all.
- **Apple Intelligence provider** running entirely on-device and requiring no
  API key. Used by default where the Mac supports it.
- **Google Gemini provider** with streaming, automatic retry on transient
  failures, and per-turn token accounting.
- **Screenshot attachments** captured with ScreenCaptureKit — the whole display
  or a dragged region — with preview and removal before sending.
- **Persistent conversations** stored with SwiftData, searchable across titles
  and message bodies, with rename and delete.
- **Usage statistics** in Settings, charting tokens per day and per model.
- **Automatic updates** via Sparkle, verified against an EdDSA signature
  embedded in the app.
- **Launch at login**, through `SMAppService`.
- Keyboard-first interaction throughout: `↩` sends, `⇧↩` inserts a newline,
  `Esc` dismisses, `⌘K` opens history, `⌘N` starts a conversation and `⌘Q`
  hides to the menu bar.

### Security

- API keys are stored in the macOS Keychain and only ever displayed masked.
- Password managers, the system Passwords app and secure text fields are never
  read, by any capture path.
- Diagnostics record outcomes, byte counts and accessibility roles only — never
  conversation content, selections or images.
- No telemetry. Selected text and screenshots reach only the provider the user
  configured.

[Unreleased]: https://github.com/Udhay-Adithya/peek/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/Udhay-Adithya/peek/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Udhay-Adithya/peek/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/Udhay-Adithya/peek/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Udhay-Adithya/peek/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Udhay-Adithya/peek/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Udhay-Adithya/peek/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Udhay-Adithya/peek/releases/tag/v0.1.0
