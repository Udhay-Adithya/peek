import AppKit
import SwiftUI

/// Hosts the settings form in a conventional window.
///
/// A real `NSWindow` rather than a SwiftUI `Settings` scene: Peek runs as an
/// accessory app with no main window, and the SwiftUI settings scene is awkward
/// to summon from a status item without a full app activation.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let settings: AppSettings
    private let engine: AssistantEngine

    init(settings: AppSettings, engine: AssistantEngine) {
        self.settings = settings
        self.engine = engine
    }

    func show() {
        if let window {
            bringToFront(window)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(settings: settings, engine: engine))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Peek Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        bringToFront(window)
    }

    /// Settings is the one surface that legitimately wants full activation:
    /// the user is typing a key and expects normal window behaviour.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
