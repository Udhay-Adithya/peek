// P0c spike — throwaway. Reads raw trackpad pressure from the private
// MultitouchSupport framework to determine whether a Force Click is
// distinguishable from a normal click, and at what threshold.
//
// ADR 0001 established that no public API exposes this. TrackWeight
// (github.com/KrishKrosh/TrackWeight) demonstrates the private route works, via
// OpenMultitouchSupport. Rather than take that package's prebuilt xcframework
// and its transitive dependency, this uses the six symbols actually needed,
// resolved with dlsym so a future OS change degrades instead of failing launch.

import AppKit
import ApplicationServices

// MARK: - Private framework layout (from OpenMultitouchSupport's public header)

struct MTPoint { var x: Float = 0; var y: Float = 0 }
struct MTVector { var position = MTPoint(); var velocity = MTPoint() }

struct MTTouch {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var fingerId: Int32 = 0
    var handId: Int32 = 0
    var normalizedPosition = MTVector()
    var total: Float = 0        // total capacitance
    var pressure: Float = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absolutePosition = MTVector()
    var field14: Int32 = 0
    var field15: Int32 = 0
    var density: Float = 0
}

typealias MTDeviceRef = UnsafeMutableRawPointer

// The touches parameter is a raw pointer rather than UnsafeMutablePointer<MTTouch>:
// a Swift struct is not Objective-C representable, so it cannot appear in a
// @convention(c) signature. Touches are loaded by stride instead, which also
// forces the struct layout to be verified explicitly rather than assumed.
typealias MTFrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

typealias FnCreateDefault = @convention(c) () -> MTDeviceRef?
typealias FnIsAvailable = @convention(c) () -> Bool
typealias FnStart = @convention(c) (MTDeviceRef?, Int32) -> OSStatus
typealias FnStop = @convention(c) (MTDeviceRef?) -> OSStatus
typealias FnRegister = @convention(c) (MTDeviceRef?, MTFrameCallback) -> Void

// MARK: - Measurement state

final class Peak {
    let lock = NSLock()
    var livePressure: Float = 0
    var liveTotal: Float = 0
    var windowPeakPressure: Float = 0
    var windowPeakTotal: Float = 0
    var windowOpen = false
    var frameCount = 0
}

let peak = Peak()
var clickIndex = 1
let logURL = URL(fileURLWithPath: "/Users/udhayxd/Projects/peek/Spike/PressureThresholdProbe/probe.log")
let start = Date()
var textView: NSTextView?

func log(_ line: String) {
    let entry = String(format: "[%7.3f] %@\n", Date().timeIntervalSince(start), line)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(entry.data(using: .utf8)!); try? h.close()
    }
    DispatchQueue.main.async {
        textView?.textStorage?.append(NSAttributedString(
            string: entry,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        textView?.scrollToEndOfDocument(nil)
    }
}

// MARK: - Multitouch frame callback (arrives on the framework's own thread)

let frameCallback: MTFrameCallback = { _, touches, count, _, _ in
    guard let touches, count > 0 else { return }
    let stride = MemoryLayout<MTTouch>.stride
    var maxPressure: Float = 0
    var maxTotal: Float = 0
    for index in 0..<Int(count) {
        let touch = touches.load(fromByteOffset: index * stride, as: MTTouch.self)
        maxPressure = max(maxPressure, touch.pressure)
        maxTotal = max(maxTotal, touch.total)
    }
    peak.lock.lock()
    peak.livePressure = maxPressure
    peak.liveTotal = maxTotal
    peak.frameCount += 1
    if peak.windowOpen {
        peak.windowPeakPressure = max(peak.windowPeakPressure, maxPressure)
        peak.windowPeakTotal = max(peak.windowPeakTotal, maxTotal)
    }
    peak.lock.unlock()
}

// MARK: - Click correlation via a listen-only tap

var tap: CFMachPort?

func tapCallback(proxy: CGEventTapProxy, type: CGEventType,
                 event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
       type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }

    // A Force Click's second detent lands AFTER mouse-down, so measure a short
    // window rather than the instant of the click.
    peak.lock.lock()
    let atDown = peak.livePressure
    peak.windowOpen = true
    peak.windowPeakPressure = atDown
    peak.windowPeakTotal = peak.liveTotal
    peak.lock.unlock()

    let index = clickIndex
    clickIndex += 1

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
        peak.lock.lock()
        let peakPressure = peak.windowPeakPressure
        let peakTotal = peak.windowPeakTotal
        peak.windowOpen = false
        peak.lock.unlock()
        log(String(format: "CLICK #%-2d  atDown=%-8.3f peakPressure=%-8.3f peakTotal=%-8.3f",
                   index, atDown, peakPressure, peakTotal))
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var device: MTDeviceRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 460),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Peek — Pressure Threshold Probe"
        window.center()
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds); tv.isEditable = false; tv.autoresizingMask = [.width]
        scroll.documentView = tv; window.contentView?.addSubview(scroll); textView = tv
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)

        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // The C struct is 96 bytes with 8-byte alignment. A mismatch here means
        // every field read afterwards is garbage, so it is checked, not assumed.
        log("MTTouch size=\(MemoryLayout<MTTouch>.size) stride=\(MemoryLayout<MTTouch>.stride) (expect 96/96)")
        log("offsets: pressure=52 total=48 state=20 — computed from the C header")
        log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        log("")

        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            log("*** dlopen FAILED: \(String(cString: dlerror()))")
            return
        }
        log("dlopen ok")

        // A generic helper cannot infer @convention(c) function metatypes, so
        // the raw pointer is resolved here and cast at each use.
        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            guard let pointer = dlsym(handle, name) else {
                log("*** dlsym missing: \(name)")
                return nil
            }
            return pointer
        }

        guard let pAvailable = sym("MTDeviceIsAvailable"),
              let pCreate = sym("MTDeviceCreateDefault"),
              let pRegister = sym("MTRegisterContactFrameCallback"),
              let pStart = sym("MTDeviceStart") else {
            log("*** required symbols unavailable")
            return
        }
        let isAvailable = unsafeBitCast(pAvailable, to: FnIsAvailable.self)
        let createDefault = unsafeBitCast(pCreate, to: FnCreateDefault.self)
        let register = unsafeBitCast(pRegister, to: FnRegister.self)
        let deviceStart = unsafeBitCast(pStart, to: FnStart.self)

        log("MTDeviceIsAvailable() = \(isAvailable())")
        guard let device = createDefault() else {
            log("*** MTDeviceCreateDefault returned NULL")
            return
        }
        self.device = device
        register(device, frameCallback)
        let status = deviceStart(device, 0)
        log("MTDeviceStart status=\(status)")
        log("")

        // Click correlation
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
        if let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: tapCallback, userInfo: nil) {
            tap = created
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0), .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            log("click tap active")
        } else {
            log("*** tapCreate failed (grant Accessibility and relaunch)")
        }

        log("")
        log("DO THIS, anywhere (including on this window):")
        log("  PHASE A: 5 NORMAL clicks.")
        log("  PHASE B: 5 hard FORCE CLICKS.")
        log("Clicks 1-5 vs 6-10 should separate on peakPressure.")
        log("")

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            peak.lock.lock()
            let frames = peak.frameCount
            let live = peak.livePressure
            peak.lock.unlock()
            if frames == 0 {
                log("no multitouch frames received yet — touch the trackpad")
            } else {
                log(String(format: "…frames=%d livePressure=%.3f", frames, live))
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
