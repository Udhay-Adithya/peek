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

---

## Addendum — exhaustive CGEventField scan (2026-09-21)

A claim circulating in sample code holds that trackpad pressure rides along on
ordinary mouse events in undocumented `CGEventField` 148, scaling past 1.0 for a
Force Click. Since ADR 0001 only tested event type 34, this was a genuinely
different mechanism and was measured separately (`Spike/PressureFieldProbe/`).

**Method.** Session-level listen-only tap on `leftMouseDown`, `leftMouseUp`,
`leftMouseDragged` and type 34. Every field from 0 to 255 was read as both
`getDoubleValueField` and `getIntegerValueField`, counting only events whose
`eventTargetUnixProcessID` was another process. The user then performed five
normal clicks followed by five hard Force Clicks, with each click's complete
non-zero field set logged and numbered.

**Result.** Clicks 1–5 (normal) and 6–10 (Force Click) produced *identical*
field signatures. The only variation was in:

| Field | Meaning | Varies because |
|---|---|---|
| 0 | mouse event number | monotonic counter |
| 1 | click state | multi-click sequence counter |
| 58, 169 | timestamps | time passes |
| 89, 90 | event UUID bytes | jitter randomly in **both** phases |

Decisive values:

- **Field 2** (`kCGMouseEventPressure`) read exactly `1.0000` on all ten clicks,
  normal and force alike. It saturates at 1.0 on an ordinary click and therefore
  carries no force information whatsoever.
- **Field 148 was identically zero**, along with every field in 145–155.
- **Zero type-34 events** arrived, independently reproducing ADR 0001.

**Conclusion.** No `CGEventField` distinguishes a Force Click from a normal
click. The circulating claim is most plausibly derived from code operating on an
**in-process `NSEvent`**, where pressure and stage do work — the original probe
recorded 11 local pressure events reaching stage 2 — rather than on a tapped
`CGEvent`. The suggested `getIntegerValueField` accessor is additionally wrong
for a 0.0–1.0 value, which truncates to 0.

ADR 0001's decision stands, now on exhaustive rather than targeted evidence.

## Remaining route, and why it is not taken by default

The user has authorised private API use. The only mechanism that could still
work is reading the trackpad's raw pressure digitiser, either through
`MultitouchSupport.framework` (`MTDeviceCreateList` /
`MTRegisterContactFrameCallback`) or by parsing raw HID reports via the public
`IOHIDManager`.

Costs, recorded so the decision is not revisited from memory:

- `MTTouch` struct layout is undocumented and has changed across macOS
  releases. Getting it wrong yields garbage values or crashes **inside a
  system callback**, taking the app down.
- It reports per-contact pressure, not Force Touch *stages*, so the
  click threshold would have to be invented and tuned per hardware generation.
- Mac App Store distribution becomes permanently impossible, on top of the
  existing App Sandbox blocker.
- It is a reverse-engineering effort whose payoff over the existing global
  hotkey is a gesture, not a capability.

Deferred rather than rejected: revisit only once the product is otherwise
complete, and behind a feature flag that degrades to the hotkey if the private
framework fails to load.

---

## Addendum 2 — Force Click implemented via a private framework (2026-09-21)

**Status of the original decision:** unchanged for *public* APIs. Force Click
remains undetectable through any public interface, now established twice.

### What changed

The user pointed to [TrackWeight](https://github.com/KrishKrosh/TrackWeight),
which reads Force Touch pressure to use the trackpad as a scale, via Takuto
Nakamura's [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport)
wrapper around the private `MultitouchSupport.framework`. That is the route
this ADR had identified and deferred; a working precedent materially reduced
the risk, and private API use was explicitly authorised.

### Measurement

A third spike (`Spike/PressureThresholdProbe/`) correlated a listen-only
`CGEventTap` on `leftMouseDown` with raw pressure frames, logging the peak
pressure in a window after each click. Five normal clicks then five Force
Clicks:

| | Peak pressure |
|---|---|
| Normal clicks | 141, 159, 169, 175, 176, 180, 193, 203, 208, 226 |
| Force Clicks | 522, 561, 577, 577, 741, 1086 |

Three findings drove the design:

- **The two populations separate cleanly**, with an empty band from 226 to 522.
  The default threshold is **350**, roughly central.
- **Pressure at mouse-down does not discriminate** (96–424, fully overlapping).
  The second detent lands *after* mouse-down, so a window must be measured
  rather than the instant of the click.
- **`total` (capacitance) does not discriminate** (0.996–1.426 for both). Only
  `pressure` carries force.

No permission was required to read the pressure feed — `AXIsProcessTrusted` was
false throughout the spike. Accessibility is still needed for the click tap.

### Implementation

- `ForceClickDetector` (PeekCore) — pure state machine, 13 tests. Guards
  against drags, double-clicks, press-and-hold, resting palms, and the ~90
  frames/second of over-threshold samples a single press produces.
- `MultitouchPressureMonitor` (app target) — six symbols resolved with
  `dlsym`, **never link-time linked**, so a future macOS that changes or
  removes the framework leaves Peek launching normally with the trigger
  reporting itself unavailable. The `MTTouch` stride is verified as 96 bytes
  before any field is read; a layout change disables the monitor rather than
  producing garbage.
- `ForceClickTrigger` (app target) — joins the tap and the pressure feed,
  handles `kCGEventTapDisabledByTimeout`/`ByUserInput` re-enabling, and is
  listen-only so no click is ever swallowed.

Pressure frames are gated at the detection threshold inside the C callback, so
resting contact costs one float comparison and never crosses to the main actor.

### Dependency decision

OpenMultitouchSupport is **not** taken as a package dependency. Its SPM
manifest pulls a prebuilt `.xcframework` from a GitHub release plus
`swift-async-algorithms`; an opaque third-party binary inside an app that holds
the user's API keys and reads their selected text is not a justified trade, and
Peek needs six of its symbols. The reused knowledge is its *public header* —
the `MTTouch` layout and symbol names — which is credited in the source.

### Consequences

- **Mac App Store is now permanently impossible**, on top of the sandbox
  blocker in ADR 0002. This was already the distribution decision.
- **Off by default.** It depends on a private framework and competes with the
  system's own Look Up, so enabling it is the user's choice.
- **The system Look Up conflict returns.** With Force Click enabled, both Peek
  and Dictionary appear unless the user turns off Trackpad › Point & Click ›
  Look up & data detectors. Settings says so and deep-links there. Still no API
  to do it programmatically.
- The hotkey and Services triggers are unaffected by any failure here.
