# ADR 0001 — Force Click cannot be detected globally with public APIs

**Status:** accepted
**Date:** 2026-09-21
**Measured on:** macOS 26.3.1 (25D771280a), MacBook with Force Touch trackpad,
`com.apple.trackpad.forceClick = 1`

## Context

The product concept requires detecting a Force Click performed in *another*
application, so the assistant can replace the system Look Up card. Apple
exposes Force Click as `NSEvent.EventType.pressure` (raw value 34) with
`stage`, `pressure` and `stageTransition`. The open question was whether any
public mechanism delivers those events cross-process.

This was measured rather than assumed, before any architecture depended on it.
The probe lives in `Spike/ForcePressProbe/` and is not part of the shipping app.

## Experiment

Five probes ran concurrently in one signed `.app` with Accessibility granted
(`AXIsProcessTrusted = true`):

| Probe | Mechanism |
|---|---|
| A  | `NSEvent.addGlobalMonitorForEvents(matching: .pressure)` |
| B1 | `CGEvent.tapCreate` @ `.cghidEventTap`, mask bit 34 |
| B2 | `CGEvent.tapCreate` @ `.cgSessionEventTap`, mask bit 34 |
| B3 | `CGEvent.tapCreate` @ `.cgAnnotatedSessionEventTap`, mask bit 34 |
| C  | `NSEvent.addLocalMonitorForEvents(matching: .pressure)` — baseline |

Each probe carried a `leftMouseDown` **control** on the same mask. Target
process was read from `CGEventField.eventTargetUnixProcessID` rather than
`NSWorkspace.frontmostApplication`, which lags and misattributes.

The control is what makes the result interpretable: without it, "saw no
pressure events" is indistinguishable from "saw nothing at all". An earlier
version of this probe lacked a cross-process control and was discarded.

## Results

Force clicks performed in Zen, Notes, Ghostty and the probe's own window:

| Probe | pressure events | of which cross-process | control mouseDown | of which cross-process |
|---|---|---|---|---|
| A  global monitor | **0** | 0 | 4 | **4** |
| B1 tap @ HID | **0** | 0 | 7 | **5** |
| B2 tap @ session | **0** | 0 | 7 | **5** |
| B3 tap @ annotated session | **0** | 0 | 7 | **4** |
| C  local monitor | **11** | 0 | — | — |

All three taps were created successfully, never disabled during the run, and
demonstrably received `leftMouseDown` from other processes.

## Conclusion

**Type 34 is not carried by the CGEvent tap infrastructure or by NSEvent global
monitors at all.**

The decisive comparison is within a single run: the local monitor received 11
pressure events while all three taps received **zero** — including the pressure
events destined for the probe's *own* process, which the taps were positioned to
see. This is not a permissions problem and not a cross-process delivery problem.
Pressure events are synthesised for delivery into the target application's own
event stream and never traverse the tap chain.

Corollaries:

- No tap location helps. HID, session and annotated session all behave identically.
- Granting Accessibility does not change the outcome.
- Since the events never reach a tap, they also **cannot be suppressed** by one.
  Intercepting the system Look Up was never possible by this route regardless of
  whether it would have been acceptable.

## Decision

Force Click is **not** an invocation trigger for Peek. It is removed from the
roadmap as a primary mechanism. The app invokes through a trigger ladder of
mechanisms that were verified to work:

1. **Global hotkey** — `RegisterEventHotKey`, no permissions, any input device.
2. **Services menu** (`NSServices`) — "Ask Peek" in every Cocoa app's context
   and Services menu; supplies the selection via `NSPasteboard` for free, needs
   no permissions, and the user can bind their own shortcut in System Settings.
3. **Menu bar item.**

## Consequences

- The system's Look Up behaviour does not need to be disabled, because we no
  longer compete with it. The onboarding step telling users to turn it off is
  dropped.
- Accessibility permission is still wanted, but for *reading the selection*
  (`kAXSelectedTextAttribute`), not for detecting invocation. It becomes an
  optional enhancement rather than a hard dependency, since the Services path
  supplies text without it.
- Removing the event tap removes the tap-lifecycle failure modes entirely:
  no `kCGEventTapDisabledByTimeout` re-enable logic, no silent disable on
  signature change.
- This materially improves the App Store story. The tap was one of two
  blockers; cross-process Accessibility remains the other, so distribution is
  still Developer ID first (see ADR 0002).

## Alternatives rejected

- **Private APIs / `IOHIDManager` on the raw trackpad device.** Reading the
  pressure digitiser directly would likely work, but requires either private
  SPI or Input Monitoring against raw HID, is unsupportable across hardware,
  and was explicitly excluded by the project brief.
- **Polling `NSEvent.pressure` on a timer.** The property is only meaningful on
  a pressure event; there is nothing to poll.
- **AX notification on selection change as a proxy.** Fires on ordinary
  selection, not on an intentional gesture. Would invoke constantly.
