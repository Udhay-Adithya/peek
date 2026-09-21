# Performance baseline

Measured, not asserted. Re-run with:

```bash
xcodebuild -project Peek.xcodeproj -scheme Peek -configuration Release build
PEEK_BENCHMARK=1 <built>/Peek.app/Contents/MacOS/Peek
```

The harness (`App/Peek/Diagnostics/PerformanceHarness.swift`) is gated behind
`PEEK_BENCHMARK=1` and never runs for a real user.

## Baseline — 2026-09-21, Apple Silicon, macOS 26.3.1, Release build

### Panel appearance (60 iterations, after warm-up)

| Measure | min | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| `show()` call | 1.4 | **2.3** | 5.5 | 6.9 | 12.3 |
| `show()` → laid out | 7.8 | **42.5** | 47.1 | 49.0 | 61.9 |

All values in milliseconds. Percentiles rather than a mean, because a p99
stall is what a user actually notices.

**`show()` is 2.3 ms at p50.** That is Peek's own work on the path between the
keystroke and the window appearing: placement arithmetic plus `orderFront`.
It is this small *because* the panel and its SwiftUI hosting view are built
once at launch — see the launch table below for what that costs.

**`show()` → laid out is ~42 ms at p50**, of which only ~2 ms is ours. The
remainder is AppKit window ordering, the window-server round trip and the Core
Animation commit. Worth being precise about what this number is and is not: it
measures until the next main run-loop turn completes after `show()`, which is
the earliest point the content is laid out and committed for drawing. It is a
proxy for "the user can see it", not a display-refresh measurement.

### Launch to menu-bar ready — 437 ms total

| Phase | Cost |
|---|---|
| Panel pre-warm (`NSPanel` + `NSHostingView`) | 159.6 ms |
| Main menu construction | 101.1 ms |
| `AppSettings` (incl. Apple Intelligence availability probe) | 15.9 ms |
| SwiftData container (on-disk) | 10.4 ms |
| Services registration | 2.3 ms |
| Remainder (dyld, AppKit init, status item) | ~148 ms |

## Conclusions

**Not optimising launch.** 437 ms happens once per login for a resident
menu-bar utility, and 160 ms of it is the deliberate pre-warm that buys the
2.3 ms invocation path. Trading a once-per-session cost for a
dozens-of-times-a-day cost is the right direction, so this is a design
outcome rather than a regression.

**A measured assumption was wrong.** The on-disk SwiftData container was
expected to dominate launch and was instead 10.4 ms — 2% of it. Had this been
"optimised" from intuition, the work would have gone entirely to the wrong
place. The two real costs are panel pre-warm and first-menu construction,
neither of which was suspected beforehand.

**Panel appearance is dominated by the system, not by Peek.** With `show()` at
2.3 ms, there is no meaningful headroom left in our code; further gains would
have to come from not ordering a window at all.

## Deliberately not measured yet

- Streaming throughput and per-token UI cost under a long response.
- Memory growth across many conversations.
- Screenshot capture and encoding latency.
- Context capture latency per app family (Accessibility vs clipboard
  fallback); the Accessibility path is bounded by a 250 ms messaging timeout by
  construction.
