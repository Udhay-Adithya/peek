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
    private let onQuit: () -> Void
    private let menu: NSMenu

    /// Whether the global shortcut is actually live.
    enum HotKeyStatus {
        case registered(HotKey)
        case unavailable(HotKey)
    }

    var hotKeyStatus: HotKeyStatus = .unavailable(.defaultInvoke) {
        didSet { buildMenu() }
    }

    /// Reflects in-flight assistant work. Set from the streaming layer later.
    var isBusy: Bool = false {
        didSet { guard isBusy != oldValue else { return }; updateAppearance() }
    }

    init(onPrimaryAction: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.onPrimaryAction = onPrimaryAction
        self.onOpenSettings = onOpenSettings
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
        let symbol = isBusy ? "sparkles" : "text.magnifyingglass"
        button.image = Self.symbolImage(named: symbol, fallback: "magnifyingglass")
        button.image?.isTemplate = true
        button.toolTip = isBusy ? "Peek — thinking…" : "Peek"
    }

    /// SF Symbol availability varies by OS version; fall back rather than
    /// shipping a status item with no image at all.
    private static func symbolImage(named name: String, fallback: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Peek")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "Peek")
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

    @objc private func handleQuit() { onQuit() }
}
