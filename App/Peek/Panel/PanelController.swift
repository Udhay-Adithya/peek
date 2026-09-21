import AppKit
import SwiftUI
import PeekCore

/// Owns the single, long-lived assistant panel.
///
/// The panel and its SwiftUI hosting view are built once at launch and reused.
/// Invocation then costs only a placement calculation and an `orderFront`,
/// which is what keeps appearance latency in the tens of milliseconds rather
/// than paying view-construction cost on every trigger.
@MainActor
final class PanelController {

    private let panel: PeekPanel
    private let viewModel: PanelViewModel
    private var outsideClickMonitor: Any?

    private static let defaultSize = CGSize(width: 440, height: 300)
    private static let minSize = CGSize(width: 360, height: 200)

    var isVisible: Bool { panel.isVisible }

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        panel = PeekPanel(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        embedContent()
    }

    // MARK: - Configuration

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.minSize = Self.minSize

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        // Above ordinary windows, below the menu bar and system alerts.
        panel.level = .floating

        // Follow the user across Spaces and appear over full-screen apps, which
        // is what a system-wide lookup utility is expected to do.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.onDismiss = { [weak self] in self?.hide() }
    }

    private func embedContent() {
        // System material for the chrome. Liquid Glass is designed for controls
        // layered over your own content; a full-bleed glass background over
        // arbitrary desktop content loses legibility fast, so the panel uses
        // the same HUD material Spotlight and the Dictionary card use.
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: PanelRootView(model: viewModel))
        host.autoresizingMask = [.width, .height]
        host.frame = background.bounds
        background.addSubview(host)

        panel.contentView = background
    }

    // MARK: - Presentation

    func toggle(anchor: CGRect? = nil) {
        isVisible ? hide() : show(anchor: anchor)
    }

    /// Shows the panel near `anchor`, defaulting to the mouse location.
    ///
    /// `NSEvent.mouseLocation` is already in the bottom-left-origin screen space
    /// that ``PanelPlacement`` expects, so no flipping is needed here.
    func show(anchor: CGRect? = nil) {
        // Read the frontmost app *before* ordering the panel front. The panel
        // is non-activating so this would almost certainly still be correct
        // afterwards, but "almost certainly" is not worth depending on.
        let frontApp = FrontmostApp.current()

        let target = anchor ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screens = NSScreen.screens.map {
            PanelPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }

        if let placement = PanelPlacement.place(panelSize: panel.frame.size,
                                                anchor: target,
                                                screens: screens) {
            panel.setFrameOrigin(placement.origin)
        }

        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()

        // Panel first, context second. Capture is IPC into another process and
        // must never sit between the trigger and the panel appearing.
        viewModel.refreshContext(frontApp: frontApp)
    }

    func hide() {
        removeOutsideClickMonitor()
        panel.orderOut(nil)
    }

    // MARK: - Dismiss on outside click

    /// A global monitor for mouse-down outside the panel.
    ///
    /// Verified during the P0 spike: global monitors do receive cross-process
    /// mouse events without any permission grant — it is only pressure events
    /// they never see. Installed only while visible, so there is no idle
    /// system-wide observer.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let monitor = outsideClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        outsideClickMonitor = nil
    }

    // Isolated so it can touch main-actor state. PanelController is owned by
    // the app delegate for the process lifetime, so this is belt-and-braces
    // rather than a path that runs in practice.
    isolated deinit {
        removeOutsideClickMonitor()
    }
}
