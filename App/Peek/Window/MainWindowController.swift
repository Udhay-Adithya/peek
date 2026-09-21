import AppKit
import SwiftUI

/// Hosts the expanded conversation window.
///
/// A conventional `NSWindow`, created lazily and kept alive after closing so
/// reopening is instant. Unlike the panel this window activates normally: the
/// user is reading and typing at length and expects standard window behaviour,
/// including appearing in the window menu and Mission Control.
@MainActor
final class MainWindowController {

    private var window: NSWindow?
    private let content: () -> AnyView

    init(content: @escaping () -> AnyView) {
        self.content = content
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let window {
            activate(window)
            return
        }

        let hosting = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Peek"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 960, height: 640))
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.center()

        // Restores size and position across launches.
        window.setFrameAutosaveName("PeekMainWindow")

        self.window = window
        activate(window)
    }

    private func activate(_ window: NSWindow) {
        // A regular window needs the app to be a regular app, or it cannot be
        // focused properly from an accessory-policy process.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Returns the app to menu-bar-only once no ordinary window remains.
    ///
    /// Without this, Peek would keep a Dock icon forever after the first time
    /// the window is opened.
    func restoreAccessoryPolicyIfNeeded() {
        let hasVisibleRegularWindow = NSApp.windows.contains {
            $0.isVisible && !($0 is PeekPanel) && $0.styleMask.contains(.titled)
        }
        guard !hasVisibleRegularWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
