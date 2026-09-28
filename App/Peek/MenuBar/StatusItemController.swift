import AppKit

/// Owns the menu-bar presence.
///
/// Left click toggles the panel; right click (or click-and-hold) opens the
/// menu. That split is the macOS convention for status items that have a
/// primary action, and it keeps the common case to a single click.
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let onPrimaryAction: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenWindow: () -> Void
    private let onQuit: () -> Void
    private let menu: NSMenu
    private var twinkleTimer: Timer?
    private var twinkleFrame = 0

    /// Whether the global shortcut is actually live.
    enum HotKeyStatus {
        case registered(HotKey)
        case unavailable(HotKey)
    }

    var hotKeyStatus: HotKeyStatus = .unavailable(.defaultInvoke) {
        didSet { buildMenu() }
    }

    /// Reflects in-flight assistant work: the glyph's stars twinkle while true.
    var isBusy: Bool = false {
        didSet { guard isBusy != oldValue else { return }; updateAppearance() }
    }

    init(onPrimaryAction: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         onOpenWindow: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.onPrimaryAction = onPrimaryAction
        self.onOpenSettings = onOpenSettings
        self.onOpenWindow = onOpenWindow
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.menu = NSMenu()

        buildMenu()
        configureButton()
        updateAppearance()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Peek")
    }

    private func buildMenu() {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Peek", action: #selector(handleOpen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        switch hotKeyStatus {
        case .registered(let key):
            let item = NSMenuItem(title: "Shortcut: \(key.displayString)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .unavailable(let key):
            let item = NSMenuItem(title: "\(key.displayString) unavailable — in use by another app",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let window = NSMenuItem(title: "Conversations…", action: #selector(handleOpenWindow), keyEquivalent: "")
        window.target = self
        menu.addItem(window)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(handleSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Peek", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func updateAppearance() {
        guard let button = statusItem.button else { return }
        button.toolTip = isBusy ? "Peek — thinking…" : "Peek"

        // Reduce Motion keeps the busy state static; the tooltip still says so.
        if isBusy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startTwinkling()
        } else {
            stopTwinkling()
            button.image = StatusGlyph.idle
        }
    }

    private func startTwinkling() {
        guard twinkleTimer == nil else { return }
        twinkleFrame = 0
        statusItem.button?.image = StatusGlyph.busyFrames[0]

        let timer = Timer(timeInterval: StatusGlyph.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceTwinkle() }
        }
        // Common modes, so the stars keep moving while the status menu is open.
        RunLoop.main.add(timer, forMode: .common)
        twinkleTimer = timer
    }

    private func advanceTwinkle() {
        twinkleFrame = (twinkleFrame + 1) % StatusGlyph.busyFrames.count
        statusItem.button?.image = StatusGlyph.busyFrames[twinkleFrame]
    }

    private func stopTwinkling() {
        twinkleTimer?.invalidate()
        twinkleTimer = nil
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { onPrimaryAction(); return }

        let wantsMenu = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)

        if wantsMenu {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            // Detach immediately, otherwise the menu hijacks the next left click.
            statusItem.menu = nil
        } else {
            onPrimaryAction()
        }
    }

    @objc private func handleOpen() { onPrimaryAction() }

    @objc private func handleSettings() {
        onOpenSettings()
    }

    @objc private func handleOpenWindow() {
        onOpenWindow()
    }

    @objc private func handleQuit() { onQuit() }
}
