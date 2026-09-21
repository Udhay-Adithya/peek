import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var hotKeys: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar resident: no Dock icon, no app switcher entry. Paired with
        // LSUIElement so the policy holds from launch rather than flickering.
        NSApp.setActivationPolicy(.accessory)

        // Built once, at launch, and reused for every invocation. Panel
        // appearance latency is the number that matters for this product, and
        // constructing an NSPanel plus its SwiftUI hosting view on demand costs
        // far more than positioning and ordering an existing one.
        let panel = PanelController()
        self.panel = panel

        let statusItem = StatusItemController(
            onPrimaryAction: { [weak panel] in panel?.toggle() },
            onQuit: { NSApp.terminate(nil) }
        )
        self.statusItem = statusItem

        // Primary trigger. Registration can legitimately fail when another app
        // already owns the shortcut, and a silently dead hotkey is
        // indistinguishable from a broken app, so it is surfaced in the menu
        // bar rather than swallowed.
        let hotKeys = HotKeyManager()
        let registered = hotKeys.register(.defaultInvoke) { [weak panel] in
            panel?.toggle()
        }
        self.hotKeys = hotKeys
        statusItem.hotKeyStatus = registered ? .registered(.defaultInvoke)
                                             : .unavailable(.defaultInvoke)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
