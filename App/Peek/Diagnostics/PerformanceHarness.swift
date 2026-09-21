import AppKit
import OSLog

/// Measures the latency claims this product is built on.
///
/// The brief required measuring before optimising, and panel appearance
/// latency is the number that actually matters for a utility like this — cold
/// launch happens once a week, the panel opens dozens of times a day.
///
/// Gated behind `PEEK_BENCHMARK=1` so it never runs for a real user, and
/// reported as percentiles rather than a mean, because a p99 stall is what
/// someone notices.
@MainActor
enum PerformanceHarness {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "benchmark")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PEEK_BENCHMARK"] == "1"
    }

    /// Recorded at the very start of `main`, so launch cost includes
    /// everything the app does before it is usable.
    static let processStart = ProcessInfo.processInfo.systemUptime

    /// Per-phase launch timings, to locate cost rather than guess at it.
    private nonisolated(unsafe) static var phases: [(String, Double)] = []

    @discardableResult
    static func phase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try body()
        phases.append((name, (ProcessInfo.processInfo.systemUptime - start) * 1000))
        return result
    }

    static func recordLaunchComplete() {
        let elapsed = (ProcessInfo.processInfo.systemUptime - processStart) * 1000
        logger.log("launch: \(elapsed, format: .fixed(precision: 1), privacy: .public) ms to menu-bar ready")
        if isEnabled {
            for (name, duration) in phases {
                print(String(format: "  %-28@ %7.1f ms", name as NSString, duration))
            }
            print(String(format: "launch to menu-bar ready: %.1f ms", elapsed))
        }
    }

    /// Times repeated show/hide cycles of the real panel.
    ///
    /// Two numbers are taken per iteration:
    ///
    /// * **show()** — placement arithmetic plus `orderFront`, which is the work
    ///   on the path between the user's keystroke and the window appearing.
    /// * **ready** — from `show()` until the next main run-loop turn completes,
    ///   which is the earliest point the panel's content has been laid out and
    ///   committed for drawing. A closer proxy for "the user can see it" than
    ///   `show()` alone, without pretending to measure the display refresh.
    static func runPanelBenchmark(iterations: Int, panel: PanelController) async {
        print("\n=== Peek panel latency (\(iterations) iterations) ===")

        var showSamples: [Double] = []
        var readySamples: [Double] = []

        // Warm-up: the first show pays one-off SwiftUI and window-server costs
        // that would otherwise dominate the sample.
        panel.show()
        await nextRunLoopTurn()
        panel.hide()
        await nextRunLoopTurn()

        for _ in 0..<iterations {
            let start = ProcessInfo.processInfo.systemUptime
            panel.show()
            let afterShow = ProcessInfo.processInfo.systemUptime

            await nextRunLoopTurn()
            let afterReady = ProcessInfo.processInfo.systemUptime

            showSamples.append((afterShow - start) * 1000)
            readySamples.append((afterReady - start) * 1000)

            panel.hide()
            await nextRunLoopTurn()
        }

        report("show() call", showSamples)
        report("show() → laid out", readySamples)
        print("===============================================\n")
    }

    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func report(_ label: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        func percentile(_ value: Double) -> Double {
            let index = Int((Double(sorted.count - 1) * value).rounded())
            return sorted[index]
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        print(String(format: "%-20@  min %6.2f  p50 %6.2f  p90 %6.2f  p99 %6.2f  max %6.2f  mean %6.2f ms",
                     label as NSString,
                     sorted.first ?? 0, percentile(0.5), percentile(0.9),
                     percentile(0.99), sorted.last ?? 0, mean))
        logger.log("\(label, privacy: .public) p50=\(percentile(0.5), format: .fixed(precision: 2), privacy: .public)ms p99=\(percentile(0.99), format: .fixed(precision: 2), privacy: .public)ms")
    }
}
