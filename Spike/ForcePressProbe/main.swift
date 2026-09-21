// P0 spike — throwaway. Measures which public mechanisms actually deliver
// NSEvent.EventType.pressure (raw 34) for OTHER processes on this macOS build.
//
// Three probes run at once:
//   A. NSEvent.addGlobalMonitorForEvents(matching: .pressure)
//   B. CGEventTap (session, listen-only) with bit 34 set in the mask
//   C. NSEvent.addLocalMonitorForEvents(matching: .pressure)  <- baseline, own window
//
// Left mouse down/up are tapped as a CONTROL: if those arrive but pressure does
// not, the tap is alive and type 34 is simply not delivered. That distinction is
// the whole point of this spike.

import AppKit
import ApplicationServices

let kPressureEventType: UInt32 = 34   // NSEvent.EventType.pressure.rawValue

// MARK: - Results

final class Probe {
    var pressureCount = 0
    var maxStage = -1
    var stage2Transitions = 0
    var otherAppHits = 0
}

let globalProbe = Probe()
let tapProbe = Probe()
let localProbe = Probe()
var controlMouseDownCount = 0
var tapDisabledCount = 0

let logURL = URL(fileURLWithPath: "/Users/udhayxd/Projects/peek/Spike/ForcePressProbe/probe.log")
let startDate = Date()

var textView: NSTextView?

func log(_ line: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(startDate))
    let entry = "[\(t)] \(line)\n"
    FileHandle.standardError.write(entry.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(entry.data(using: .utf8)!)
        try? h.close()
    }
    DispatchQueue.main.async {
        guard let tv = textView else { return }
        tv.textStorage?.append(NSAttributedString(
            string: entry,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        tv.scrollToEndOfDocument(nil)
    }
}

func frontApp() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
}

func isSelfFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
}

/// Record a pressure observation. Returns true if it was a fresh 0/1 -> 2 transition.
func record(_ probe: Probe, stage: Int, pressure: Float, transition: CGFloat, source: String) {
    probe.pressureCount += 1
    if !isSelfFrontmost() { probe.otherAppHits += 1 }
    if stage > probe.maxStage {
        probe.maxStage = stage
        log("\(source): new max stage=\(stage) pressure=\(String(format: "%.2f", pressure)) front=\(frontApp())")
    }
    if stage >= 2 {
        probe.stage2Transitions += 1
        if probe.stage2Transitions <= 8 {
            log(">>> \(source): FORCE CLICK stage=\(stage) pressure=\(String(format: "%.2f", pressure)) transition=\(String(format: "%.2f", transition)) front=\(frontApp())")
        }
    }
}

// MARK: - Probe B: CGEventTap

func tapCallback(proxy: CGEventTapProxy,
                 type: CGEventType,
                 event: CGEvent,
                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let raw = type.rawValue

    if raw == CGEventType.tapDisabledByTimeout.rawValue ||
       raw == CGEventType.tapDisabledByUserInput.rawValue {
        tapDisabledCount += 1
        log("!!! TAP DISABLED (raw=\(raw)) — re-enabling")
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if raw == kPressureEventType {
        // Prefer the AppKit view of the event; fall back to raw CG fields.
        if let ns = NSEvent(cgEvent: event), ns.type == .pressure {
            record(tapProbe, stage: ns.stage, pressure: ns.pressure,
                   transition: ns.stageTransition, source: "B/EVENT-TAP")
        } else {
            let p = event.getDoubleValueField(.mouseEventPressure)
            record(tapProbe, stage: -99, pressure: Float(p), transition: 0,
                   source: "B/EVENT-TAP(raw, NSEvent conversion failed)")
        }
    } else if raw == CGEventType.leftMouseDown.rawValue {
        controlMouseDownCount += 1
        if controlMouseDownCount <= 3 {
            log("CONTROL: leftMouseDown seen (tap is alive) front=\(frontApp())")
        }
    }

    return Unmanaged.passUnretained(event)   // listen-only: never swallow
}

var eventTap: CFMachPort?

func startEventTap() {
    let mask: CGEventMask =
        (1 << kPressureEventType) |
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.leftMouseUp.rawValue)

    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                      place: .headInsertEventTap,
                                      options: .listenOnly,
                                      eventsOfInterest: mask,
                                      callback: tapCallback,
                                      userInfo: nil) else {
        log("B/EVENT-TAP: *** tapCreate FAILED — Accessibility/Input Monitoring not granted ***")
        return
    }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("B/EVENT-TAP: created, mask includes bit 34 (pressure)")
}

// MARK: - Summary

func printSummary() {
    log("")
    log("================ RESULT ================")
    log("A  global monitor  : pressure=\(globalProbe.pressureCount) maxStage=\(globalProbe.maxStage) stage2=\(globalProbe.stage2Transitions) fromOtherApps=\(globalProbe.otherAppHits)")
    log("B  event tap       : pressure=\(tapProbe.pressureCount) maxStage=\(tapProbe.maxStage) stage2=\(tapProbe.stage2Transitions) fromOtherApps=\(tapProbe.otherAppHits)")
    log("C  local monitor   : pressure=\(localProbe.pressureCount) maxStage=\(localProbe.maxStage) stage2=\(localProbe.stage2Transitions)")
    log("   control mouseDown via tap: \(controlMouseDownCount)   tapDisabled events: \(tapDisabledCount)")
    log("   AXIsProcessTrusted: \(AXIsProcessTrusted())")
    log("========================================")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Peek — Force Click Probe (P0)"
        window.center()

        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        window.contentView?.addSubview(scroll)
        textView = tv

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("pid \(getpid())  AXIsProcessTrusted=\(AXIsProcessTrusted())")
        log("")

        if !AXIsProcessTrusted() {
            log("Accessibility NOT granted — prompting. Grant it, then RE-RUN this probe.")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }

        // Probe A — global monitor
        NSEvent.addGlobalMonitorForEvents(matching: [.pressure]) { e in
            record(globalProbe, stage: e.stage, pressure: e.pressure,
                   transition: e.stageTransition, source: "A/GLOBAL-MONITOR")
        }
        log("A/GLOBAL-MONITOR: installed for .pressure")

        // Probe C — local monitor (baseline)
        NSEvent.addLocalMonitorForEvents(matching: [.pressure]) { e in
            record(localProbe, stage: e.stage, pressure: e.pressure,
                   transition: e.stageTransition, source: "C/LOCAL-MONITOR")
            return e
        }
        log("C/LOCAL-MONITOR: installed for .pressure")

        // Probe B — event tap
        startEventTap()

        log("")
        log("INSTRUCTIONS:")
        log("  1. Force click INSIDE this window first (baseline, proves C works).")
        log("  2. Switch to Safari/Notes/Finder, select a word, FORCE CLICK it.")
        log("  3. Do that 3-4 times in different apps.")
        log("  4. Summary auto-prints every 15s; full log at Spike/ForcePressProbe/probe.log")
        log("")

        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in printSummary() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        printSummary()
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
