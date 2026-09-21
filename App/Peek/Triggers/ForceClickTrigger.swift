import AppKit
import OSLog
import PeekCore

/// Force Click as an invocation trigger.
///
/// Combines two feeds, because neither alone is sufficient: a `CGEventTap`
/// supplies the click (proven to work cross-process in the P0 spike, unlike
/// pressure events) and ``MultitouchPressureMonitor`` supplies the force. The
/// decision itself lives in ``ForceClickDetector`` so it can be tested.
///
/// Optional by construction. It needs Accessibility for the tap and depends on
/// a private framework for pressure, so every failure path here degrades to
/// "unavailable" and leaves the hotkey and Services triggers untouched.
@MainActor
final class ForceClickTrigger {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "forceclick")

    /// Whether this Mac can support the trigger at all.
    static var isSupported: Bool {
        MultitouchPressureMonitor.isAvailable
    }

    private let onForceClick: (CGPoint) -> Void
    private var detector: ForceClickDetector
    private var monitor: MultitouchPressureMonitor?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isRunning = false

    init(configuration: ForceClickDetector.Configuration = .init(),
         onForceClick: @escaping (CGPoint) -> Void) {
        self.detector = ForceClickDetector(configuration: configuration)
        self.onForceClick = onForceClick
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        guard AXIsProcessTrusted() else {
            Self.logger.debug("not starting: Accessibility not granted")
            return false
        }
        guard let monitor = MultitouchPressureMonitor() else {
            Self.logger.debug("not starting: multitouch unavailable")
            return false
        }

        guard startTap() else {
            Self.logger.error("not starting: event tap could not be created")
            return false
        }

        // Gated at the detection threshold: anything below it can never
        // produce a Force Click, so it never needs to cross threads.
        let started = monitor.startMonitoring(gate: detector.configuration.threshold) { [weak self] pressure in
            // Arrives on MultitouchSupport's own thread.
            Task { @MainActor [weak self] in
                self?.handlePressure(pressure)
            }
        }
        guard started else {
            stopTap()
            return false
        }

        self.monitor = monitor
        isRunning = true
        Self.logger.debug("force click trigger started threshold=\(self.detector.configuration.threshold, privacy: .public)")
        return true
    }

    func stop() {
        guard isRunning else { return }
        monitor?.stopMonitoring()
        monitor = nil
        stopTap()
        isRunning = false
        Self.logger.debug("force click trigger stopped")
    }

    // MARK: - Event handling

    private func handlePressure(_ pressure: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        if case .forceClick(let point) = detector.handle(.pressure(pressure, time: now)) {
            Self.logger.debug("force click detected")
            onForceClick(point)
        }
    }

    /// Takes plain values rather than the `CGEvent` itself.
    ///
    /// `CGEvent` is not `Sendable`, and it is also owned by the tap callback —
    /// reading what is needed there and passing primitives avoids both the
    /// concurrency violation and any question of lifetime.
    fileprivate func handleTapEvent(kind: TapEventKind, location: CGPoint, clickCount: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        switch kind {
        case .down:
            _ = detector.handle(.clickBegan(at: location, time: now, clickCount: clickCount))
        case .up:
            _ = detector.handle(.clickEnded(time: now))
        case .dragged:
            _ = detector.handle(.moved(to: location, time: now))
        }
    }

    fileprivate enum TapEventKind: Sendable {
        case down, up, dragged
    }

    fileprivate func reenableTap() {
        guard let tap else { return }
        // The system disables a tap that is slow or when secure input engages.
        // Left unhandled, the trigger dies silently and stays dead.
        Self.logger.debug("event tap was disabled by the system, re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Tap

    private func startTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              // Listen only: swallowing clicks
                                              // system-wide is never acceptable.
                                              options: .listenOnly,
                                              eventsOfInterest: mask,
                                              callback: forceClickTapCallback,
                                              userInfo: context) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)

        tap = created
        runLoopSource = source
        return true
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    isolated deinit {
        stop()
    }
}

/// Top-level: a `@convention(c)` callback cannot capture context, so the owner
/// travels through `userInfo`.
private func forceClickTapCallback(proxy: CGEventTapProxy,
                                   type: CGEventType,
                                   event: CGEvent,
                                   userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let trigger = Unmanaged<ForceClickTrigger>.fromOpaque(userInfo).takeUnretainedValue()

    if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
       type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
        MainActor.assumeIsolated { trigger.reenableTap() }
        return Unmanaged.passUnretained(event)
    }

    // Read everything needed from the event here: it is not Sendable and is
    // owned by this callback.
    let kind: ForceClickTrigger.TapEventKind
    switch type {
    case .leftMouseDown: kind = .down
    case .leftMouseUp:   kind = .up
    case .leftMouseDragged: kind = .dragged
    default: return Unmanaged.passUnretained(event)
    }
    let location = event.location
    let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))

    // The run loop source is attached to the main run loop, so this callback
    // already runs on the main thread.
    MainActor.assumeIsolated {
        trigger.handleTapEvent(kind: kind, location: location, clickCount: clickCount)
    }
    return Unmanaged.passUnretained(event)
}
