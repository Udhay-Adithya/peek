import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private var panel: PanelController?

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

        statusItem = StatusItemController(
            onPrimaryAction: { [weak panel] in panel?.toggle() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
