// P0b spike — throwaway. Tests whether trackpad pressure rides along on
// ORDINARY mouse events as undocumented CGEventFields, cross-process.
//
// ADR 0001 established that NSEvent type 34 (.pressure) never traverses a
// CGEventTap. This probe tests a different claim: that leftMouseDown /
// leftMouseDragged carry a pressure value in an undocumented field (reportedly
// 148), scaling past 1.0 for a Force Click.
//
// Scans a range of fields rather than trusting one number, reads each as BOTH
// double and integer (a 0..1 value read as an integer truncates to 0, which is
// how this kind of lead usually gets mis-reported), and only counts events
// whose target pid is another process.

import AppKit
import ApplicationServices

let selfPID = getpid()
let scannedFields: [UInt32] = Array(0...255)   // exhaustive: no assumption about which field carries pressure
let logURL = URL(fileURLWithPath: "/Users/udhayxd/Projects/peek/Spike/PressureFieldProbe/probe.log")
let startDate = Date()
var textView: NSTextView?

func log(_ line: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(startDate))
    let entry = "[\(t)] \(line)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(entry.data(using: .utf8)!); try? h.close()
    }
    DispatchQueue.main.async {
        textView?.textStorage?.append(NSAttributedString(
            string: entry,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        textView?.scrollToEndOfDocument(nil)
    }
}

final class FieldStats {
    var maxDouble: Double = -.infinity
    var minDouble: Double = .infinity
    var maxInt: Int64 = .min
    var nonZeroCount = 0
    var exceededOne = 0
}

var stats: [UInt32: FieldStats] = {
    var d = [UInt32: FieldStats]()
    for f in scannedFields { d[f] = FieldStats() }
    return d
}()

var crossProcessMouseEvents = 0
var clickIndex = 1
var observedPIDs = Set<pid_t>()
var tap: CFMachPort?

/// Records one mouse event's field values.
func sample(_ event: CGEvent, label: String, targetPID: pid_t) {
    crossProcessMouseEvents += 1
    observedPIDs.insert(targetPID)

    var interesting: [String] = []
    for field in scannedFields {
        guard let cgField = CGEventField(rawValue: field), let s = stats[field] else { continue }
        let d = event.getDoubleValueField(cgField)
        let i = event.getIntegerValueField(cgField)

        if d.isFinite {
            s.maxDouble = max(s.maxDouble, d)
            s.minDouble = min(s.minDouble, d)
        }
        s.maxInt = max(s.maxInt, i)
        if d != 0 { s.nonZeroCount += 1 }
        if d > 1.0 {
            s.exceededOne += 1
            interesting.append("f\(field)=\(String(format: "%.3f", d))")
        }
    }

    if !interesting.isEmpty {
        log(">>> \(label) VALUE>1.0  \(interesting.joined(separator: " ")) target=pid \(targetPID)")
    }

    // Dump the full non-zero field set for each mouse-DOWN. With a couple of
    // dozen clicks this is short enough to read, and it is the only way to see
    // whether a force click differs from a normal click in ANY field.
    if label == "mouseDown" {
        var nonZero: [String] = []
        for field in scannedFields {
            guard let cgField = CGEventField(rawValue: field) else { continue }
            let d = event.getDoubleValueField(cgField)
            if d != 0, d.isFinite {
                nonZero.append("f\(field)=\(String(format: "%.4f", d))")
            }
        }
        log("CLICK #\(clickIndex)  \(nonZero.joined(separator: " "))")
        clickIndex += 1
    }
}

func tapCallback(proxy: CGEventTapProxy, type: CGEventType,
                 event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let raw = type.rawValue
    if raw == CGEventType.tapDisabledByTimeout.rawValue ||
       raw == CGEventType.tapDisabledByUserInput.rawValue {
        log("!!! tap disabled (raw=\(raw)) — re-enabling")
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
    guard target != selfPID else { return Unmanaged.passUnretained(event) }

    switch raw {
    case CGEventType.leftMouseDown.rawValue:    sample(event, label: "mouseDown", targetPID: target)
    case CGEventType.leftMouseUp.rawValue:      sample(event, label: "mouseUp", targetPID: target)
    case CGEventType.leftMouseDragged.rawValue: sample(event, label: "mouseDragged", targetPID: target)
    case 34:                                    sample(event, label: "TYPE34", targetPID: target)
    default: break
    }
    return Unmanaged.passUnretained(event)
}

func printSummary() {
    log("")
    log("======================= FIELD SCAN =======================")
    log("cross-process mouse events sampled: \(crossProcessMouseEvents)")
    for field in scannedFields.sorted() {
        guard let s = stats[field], s.nonZeroCount > 0 || s.maxDouble > 0 else { continue }
        log(String(format: "  field %3d  maxDouble=%-10.4f minDouble=%-10.4f maxInt=%-6d nonZero=%-5d >1.0=%d",
                   Int(field), s.maxDouble, s.minDouble == .infinity ? 0 : s.minDouble,
                   s.maxInt, s.nonZeroCount, s.exceededOne))
    }
    let quiet = scannedFields.filter { (stats[$0]?.nonZeroCount ?? 0) == 0 }
    log("  always-zero fields: \(quiet.sorted().map(String.init).joined(separator: ","))")
    log("==========================================================")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Peek — Pressure Field Probe"
        window.center()
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds); tv.isEditable = false; tv.autoresizingMask = [.width]
        scroll.documentView = tv; window.contentView?.addSubview(scroll); textView = tv
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)

        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        log("scanning CGEventFields: \(scannedFields.sorted().map(String.init).joined(separator: ","))")
        log("")

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << 34)

        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .listenOnly, eventsOfInterest: mask,
                                              callback: tapCallback, userInfo: nil) else {
            log("*** tapCreate FAILED — grant Accessibility and relaunch ***")
            return
        }
        tap = created
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0), .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        log("tap created @ session, listen-only")
        log("")
        log("DO THIS in ANOTHER app (Notes/Finder — NOT this window), in order:")
        log("  PHASE A: exactly 5 NORMAL single clicks.")
        log("  PHASE B: then 5 hard FORCE CLICKS on a word.")
        log("Each click prints its full non-zero field set, numbered.")
        log("So clicks 1-5 are normal and 6-10 are force clicks.")
        log("")
        Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { _ in printSummary() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        printSummary(); return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
