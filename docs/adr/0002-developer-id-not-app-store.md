# ADR 0002 — Developer ID distribution, not the Mac App Store

**Status:** accepted
**Date:** 2026-09-21

## Context

Peek's core value is reading the text the user had selected in another
application. The user's stated preference was to ship on the Mac App Store,
on the understanding that Apple permits the necessary capabilities when there
is a valid reason.

## What is actually true

**Event taps are viable under the sandbox.** A session-level `CGEventTap` works
in a sandboxed App Store app once the user grants Input Monitoring. No
entitlement is required; the TCC prompt handles it. (This turned out to be moot
— see ADR 0001 — but it is not the blocker.)

**Cross-process Accessibility is not.** App Sandbox blocks
`AXUIElementCopyAttributeValue` against other processes and **no entitlement
unlocks it**. There is nothing to request, so "a valid reason" never enters
into it. Magnet and similar apps are on the store because their listings
predate the June 2012 sandbox mandate and run under a grandfather clause that
transfers to nobody. Every comparable app created since — Rectangle, Swish,
Loop, BetterTouchTool, Amethyst — ships outside the store for this reason.

**The clipboard fallback is independently blocked.** It relies on
`CGEvent.post`, which is currently drawing Guideline 2.4.5 rejections.

## Decision

Ship **Developer ID + hardened runtime + notarized**, distributed as a signed
DMG outside the Mac App Store. `ENABLE_APP_SANDBOX` is `NO`, recorded in
`project.yml` and `Peek.entitlements` with the reason inline.

## Consequences

- No App Store presence, and therefore no App Store update mechanism. A
  Sparkle-style updater or manual downloads will be needed eventually.
- A Developer ID Application certificate is required. The machine currently
  holds only an *Apple Development* certificate, which is enough for local
  builds but **not** for notarization or distribution.
- Peek asks for Accessibility itself, with its own explanation, rather than
  relying on App Store review to vouch for it.

## Keeping the door open

The sandbox-incompatible parts are confined to the app target:
`AccessibilitySelectionCapture` and `ClipboardSelectionCapture`. Everything in
`Packages/PeekKit` — the provider abstraction, streaming, persistence,
credential storage — is sandbox-safe, as are the Services menu trigger, the
global hotkey, and screenshot capture.

A reduced App Store build is therefore a build configuration rather than a
rewrite: Services menu plus hotkey plus chat plus screenshots, with no
automatic selection reading. That would be an honest but meaningfully smaller
product, which is why it is not the primary target.

## Also considered

- **`keychain-access-groups` for the data-protection keychain.** Setting
  `kSecUseDataProtectionKeychain` requires that entitlement or the sandbox, and
  obtaining it for a non-sandboxed Developer ID app means carrying a
  provisioning profile for no functional gain. Peek uses the file-based
  keychain instead; the only cost is a one-time authorisation prompt when the
  signing identity changes.
