import Foundation
import OSLog

/// Raw trackpad pressure, read from the private MultitouchSupport framework.
///
/// **This is the only private API in Peek**, used with explicit authorisation
/// because no public API exposes Force Click — see ADR 0001 for the
/// measurements that established that, twice.
///
/// Three deliberate constraints keep the risk contained:
///
/// * **Resolved with `dlsym`, never linked.** If MultitouchSupport changes or
///   disappears in a future macOS, Peek still launches and the Force Click
///   trigger simply reports itself unavailable. Link-time dependency on a
///   private framework would prevent the app from starting at all.
/// * **The struct layout is verified at runtime**, not assumed. A mismatch
///   makes every field read garbage, so the size is checked before any frame
///   is trusted.
/// * **Six symbols only.** No touch history, no path callbacks, no device
///   enumeration — just enough to read pressure.
///
/// Struct layout and symbol names come from the public headers of
/// Takuto Nakamura's OpenMultitouchSupport, by way of TrackWeight
/// (github.com/KrishKrosh/TrackWeight). That project's own package ships a
/// prebuilt binary xcframework and a transitive dependency, which is not a
/// trade worth making inside an app that holds the user's API keys, so only the
/// interface knowledge is reused here.
final class MultitouchPressureMonitor {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "multitouch")
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// Expected `MTTouch` size in bytes, computed from the C declaration.
    private static let expectedTouchStride = 96

    // MARK: - Layout

    struct Point { var x: Float = 0; var y: Float = 0 }
    struct Vector { var position = Point(); var velocity = Point() }

    struct Touch {
        var frame: Int32 = 0
        var timestamp: Double = 0
        var identifier: Int32 = 0
        var state: Int32 = 0
        var fingerID: Int32 = 0
        var handID: Int32 = 0
        var normalizedPosition = Vector()
        var total: Float = 0
        var pressure: Float = 0
        var angle: Float = 0
        var majorAxis: Float = 0
        var minorAxis: Float = 0
        var absolutePosition = Vector()
        var field14: Int32 = 0
        var field15: Int32 = 0
        var density: Float = 0
    }

    private typealias DeviceRef = UnsafeMutableRawPointer
    /// Touches arrive as a raw pointer: a Swift struct is not Objective-C
    /// representable and so cannot appear in a `@convention(c)` signature.
    private typealias FrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Void

    private typealias FnIsAvailable = @convention(c) () -> Bool
    private typealias FnCreateDefault = @convention(c) () -> DeviceRef?
    private typealias FnStart = @convention(c) (DeviceRef?, Int32) -> OSStatus
    private typealias FnStop = @convention(c) (DeviceRef?) -> OSStatus
    private typealias FnRegister = @convention(c) (DeviceRef?, FrameCallback) -> Void

    // MARK: - Lifecycle

    private let handle: UnsafeMutableRawPointer
    private let createDefault: FnCreateDefault
    private let start: FnStart
    private let stopFn: FnStop
    private let register: FnRegister
    private let unregister: FnRegister
    private var device: DeviceRef?

    /// Whether the framework and its symbols are present on this system.
    static var isAvailable: Bool {
        guard MemoryLayout<Touch>.stride == expectedTouchStride else { return false }
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        guard let pointer = dlsym(handle, "MTDeviceIsAvailable") else { return false }
        return unsafeBitCast(pointer, to: FnIsAvailable.self)()
    }

    init?() {
        // Verify layout before anything reads a field through it.
        guard MemoryLayout<Touch>.stride == Self.expectedTouchStride else {
            Self.logger.error("MTTouch layout mismatch: stride=\(MemoryLayout<Touch>.stride, privacy: .public) expected=\(Self.expectedTouchStride, privacy: .public) — refusing to read frames")
            return nil
        }

        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            Self.logger.error("MultitouchSupport could not be loaded")
            return nil
        }

        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            guard let pointer = dlsym(handle, name) else {
                Self.logger.error("symbol unavailable: \(name, privacy: .public)")
                return nil
            }
            return pointer
        }

        guard let pCreate = symbol("MTDeviceCreateDefault"),
              let pStart = symbol("MTDeviceStart"),
              let pStop = symbol("MTDeviceStop"),
              let pRegister = symbol("MTRegisterContactFrameCallback"),
              let pUnregister = symbol("MTUnregisterContactFrameCallback") else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        self.createDefault = unsafeBitCast(pCreate, to: FnCreateDefault.self)
        self.start = unsafeBitCast(pStart, to: FnStart.self)
        self.stopFn = unsafeBitCast(pStop, to: FnStop.self)
        self.register = unsafeBitCast(pRegister, to: FnRegister.self)
        self.unregister = unsafeBitCast(pUnregister, to: FnRegister.self)
    }

    /// Begins delivering pressure samples above `gate`.
    ///
    /// The gate exists for a measured reason: the trackpad reports roughly 90
    /// frames a second for any contact at all, and forwarding every one of
    /// those across to the main actor would be constant background work for
    /// nothing. Only frames that could possibly be a Force Click are
    /// forwarded, so resting fingers cost a comparison and nothing else.
    @discardableResult
    func startMonitoring(gate: Float, onPressure: @escaping @Sendable (Float) -> Void) -> Bool {
        guard let device = createDefault() else {
            Self.logger.error("no multitouch device")
            return false
        }
        self.device = device

        SharedPressureSink.shared.configure(gate: gate, handler: onPressure)
        register(device, multitouchFrameCallback)

        let status = start(device, 0)
        guard status == noErr else {
            Self.logger.error("MTDeviceStart failed status=\(status, privacy: .public)")
            self.device = nil
            return false
        }
        Self.logger.debug("multitouch monitoring started")
        return true
    }

    func stopMonitoring() {
        guard let device else { return }
        unregister(device, multitouchFrameCallback)
        _ = stopFn(device)
        self.device = nil
        SharedPressureSink.shared.clear()
        Self.logger.debug("multitouch monitoring stopped")
    }

    deinit {
        if let device {
            unregister(device, multitouchFrameCallback)
            _ = stopFn(device)
        }
        // The handle is intentionally not dlclose'd while a callback may still
        // be in flight on the framework's own thread.
    }
}

/// Bridges the C callback, which cannot capture context, to the owner.
private final class SharedPressureSink: @unchecked Sendable {

    static let shared = SharedPressureSink()

    private let lock = NSLock()
    private var gate: Float = .greatestFiniteMagnitude
    private var handler: (@Sendable (Float) -> Void)?

    func configure(gate: Float, handler: @escaping @Sendable (Float) -> Void) {
        lock.lock()
        self.gate = gate
        self.handler = handler
        lock.unlock()
    }

    func clear() {
        lock.lock()
        gate = .greatestFiniteMagnitude
        handler = nil
        lock.unlock()
    }

    /// Called on MultitouchSupport's own thread, at frame rate.
    func report(_ pressure: Float) {
        lock.lock()
        let shouldForward = pressure >= gate
        let handler = self.handler
        lock.unlock()
        guard shouldForward, let handler else { return }
        handler(pressure)
    }
}

/// Top-level because a `@convention(c)` function cannot capture context.
private let multitouchFrameCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Void = { _, touches, count, _, _ in
    guard let touches, count > 0 else { return }
    let stride = MemoryLayout<MultitouchPressureMonitor.Touch>.stride

    var peak: Float = 0
    for index in 0..<Int(count) {
        let touch = touches.load(fromByteOffset: index * stride,
                                 as: MultitouchPressureMonitor.Touch.self)
        peak = max(peak, touch.pressure)
    }
    SharedPressureSink.shared.report(peak)
}
