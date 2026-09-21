// P0 spike v2 — throwaway. Determines whether ANY public mechanism delivers
// NSEvent.EventType.pressure (raw 34) for OTHER processes.
//
// v1 was inconclusive: its control only ever observed clicks aimed at itself,
// so "tap saw no pressure" could not be separated from "tap saw nothing
// cross-process". v2 fixes that two ways:
//
//   * Target pid comes from the event itself (.eventTargetUnixProcessID),
//     not from NSWorkspace.frontmostApplication, which lags and lies.
//   * Every probe carries a leftMouseDown control, counted cross-process,
//     so an empty pressure column is only meaningful when its own control
//     column is non-empty.
//
// Probes:
//   A  NSEvent global monitor (.pressure)        + control global monitor (.leftMouseDown)
//   B1 CGEventTap @ cgHIDEventTap                + control
//   B2 CGEventTap @ cgSessionEventTap            + control
//   B3 CGEventTap @ cgAnnotatedSessionEventTap   + control
//   C  NSEvent local monitor (.pressure)         — baseline, must be non-zero

import AppKit
import ApplicationServices

let kPressureEventType: UInt32 = 34   // NSEvent.EventType.pressure.rawValue
let selfPID = getpid()

final class Probe {
    let name: String
    var pressure = 0
    var pressureOther = 0
    var maxStage = -1
    var stage2 = 0
    var control = 0
    var controlOther = 0
    var otherPIDs = Set<pid_t>()
    init(_ n: String) { name = n }

    var line: String {
        String(format: "%-26@ pressure=%-4d (other-proc %-4d) maxStage=%-3d stage2=%-4d | control mouseDown=%-4d (other-proc %-4d)",
               name as NSString, pressure, pressureOther, maxStage, stage2, control, controlOther)
    }
}

enum TapKind: Int, CaseIterable {
    case hid = 0, session = 1, annotated = 2
    var probeName: String {
        switch self {
        case .hid:       return "B1 tap @ HID"
        case .session:   return "B2 tap @ session"
        case .annotated: return "B3 tap @ annotated"
        }
    }
    var location: CGEventTapLocation {
        switch self {
        case .hid:       return .cghidEventTap
        case .session:   return .cgSessionEventTap
        case .annotated: return .cgAnnotatedSessionEventTap
        }
    }
}

let probeA = Probe("A  global monitor")
let probeC = Probe("C  local monitor (baseline)")
let tapProbes: [TapKind: Probe] = {
    var d = [TapKind: Probe]()
    for k in TapKind.allCases { d[k] = Probe(k.probeName) }
    return d
}()
var taps = [TapKind: CFMachPort]()
var tapDisabledCount = 0

let logURL = URL(fileURLWithPath: "/Users/udhayxd/Projects/peek/Spike/ForcePressProbe/probe.log")
let startDate = Date()
var textView: NSTextView?

func log(_ line: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(startDate))
    let entry = "[\(t)] \(line)\n"
    FileHandle.standardError.write(entry.data(using: .utf8)!)
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

func nameFor(pid: pid_t) -> String {
    NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
}

func recordPressure(_ p: Probe, stage: Int, pressure: Float, targetPID: pid_t?) {
    p.pressure += 1
    let isOther = targetPID.map { $0 != selfPID } ?? (NSWorkspace.shared.frontmostApplication?.processIdentifier != selfPID)
    if isOther {
        p.pressureOther += 1
        if let t = targetPID { p.otherPIDs.insert(t) }
    }
    if stage > p.maxStage {
        p.maxStage = stage
        log("\(p.name): max stage -> \(stage)  target=\(targetPID.map(nameFor) ?? "n/a")")
    }
    if stage >= 2 {
        p.stage2 += 1
        if p.stage2 <= 5 {
            log(">>> \(p.name): FORCE CLICK stage=2 pressure=\(String(format: "%.2f", pressure)) target=\(targetPID.map(nameFor) ?? "n/a")")
        }
    }
}

func recordControl(_ p: Probe, targetPID: pid_t?) {
    p.control += 1
    let isOther = targetPID.map { $0 != selfPID } ?? (NSWorkspace.shared.frontmostApplication?.processIdentifier != selfPID)
    if isOther {
        p.controlOther += 1
        if let t = targetPID { p.otherPIDs.insert(t) }
        if p.controlOther <= 4 { log("\(p.name): control click from OTHER process -> \(targetPID.map(nameFor) ?? "?")") }
    }
}

func tapCallback(proxy: CGEventTapProxy, type: CGEventType,
                 event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let kindRaw = Int(bitPattern: refcon) - 1
    guard let kind = TapKind(rawValue: kindRaw), let probe = tapProbes[kind] else {
        return Unmanaged.passUnretained(event)
    }
    let raw = type.rawValue

    if raw == CGEventType.tapDisabledByTimeout.rawValue || raw == CGEventType.tapDisabledByUserInput.rawValue {
        tapDisabledCount += 1
        log("!!! \(kind.probeName) DISABLED (raw=\(raw)) — re-enabling")
        if let t = taps[kind] { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let target = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))

    if raw == kPressureEventType {
        if let ns = NSEvent(cgEvent: event), ns.type == .pressure {
            recordPressure(probe, stage: ns.stage, pressure: ns.pressure, targetPID: target)
        } else {
            recordPressure(probe, stage: -99,
                           pressure: Float(event.getDoubleValueField(.mouseEventPressure)),
                           targetPID: target)
        }
    } else if raw == CGEventType.leftMouseDown.rawValue {
        recordControl(probe, targetPID: target)
    }
    return Unmanaged.passUnretained(event)   // listen-only, never swallow
}

func startTap(_ kind: TapKind) {
    let mask: CGEventMask = (1 << kPressureEventType) | (1 << CGEventType.leftMouseDown.rawValue)
    guard let tap = CGEvent.tapCreate(tap: kind.location,
                                      place: .headInsertEventTap,
                                      options: .listenOnly,
                                      eventsOfInterest: mask,
                                      callback: tapCallback,
                                      userInfo: UnsafeMutableRawPointer(bitPattern: kind.rawValue + 1)) else {
        log("\(kind.probeName): *** tapCreate FAILED ***")
        return
    }
    taps[kind] = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("\(kind.probeName): created")
}

func printSummary() {
    log("")
    log("=========================== RESULT ===========================")
    for p in [probeA, tapProbes[.hid]!, tapProbes[.session]!, tapProbes[.annotated]!, probeC] {
        log(p.line)
    }
    let pids = Set(tapProbes.values.flatMap { $0.otherPIDs }).union(probeA.otherPIDs)
    log("other processes observed: \(pids.map(nameFor).sorted().joined(separator: ", "))")
    log("AXIsProcessTrusted=\(AXIsProcessTrusted())  tapDisabled=\(tapDisabledCount)")
    log("==============================================================")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ note: Notification) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Peek — Force Click Probe v2 (P0)"
        window.center()
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds); tv.isEditable = false; tv.autoresizingMask = [.width]
        scroll.documentView = tv; window.contentView?.addSubview(scroll); textView = tv
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)

        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)  pid \(selfPID)")
        log("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        log("")

        NSEvent.addGlobalMonitorForEvents(matching: [.pressure]) { e in
            recordPressure(probeA, stage: e.stage, pressure: e.pressure, targetPID: nil)
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            recordControl(probeA, targetPID: nil)
        }
        log("A: global monitors installed (.pressure + .leftMouseDown control)")

        NSEvent.addLocalMonitorForEvents(matching: [.pressure]) { e in
            recordPressure(probeC, stage: e.stage, pressure: e.pressure, targetPID: selfPID)
            return e
        }
        log("C: local monitor installed (.pressure)")

        for kind in TapKind.allCases { startTap(kind) }

        log("")
        log("DO THIS:  force click inside THIS window once (baseline),")
        log("          then force click text in Zen / Notes / Ghostty a few times,")
        log("          then a few NORMAL clicks in those apps.")
        log("")
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in printSummary() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { printSummary(); return true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
