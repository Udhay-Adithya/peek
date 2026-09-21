import AppKit

/// The application's main menu.
///
/// A menu-bar-only app has no menu bar of its own, which looks like it should
/// not matter — but AppKit dispatches the standard editing commands through the
/// **Edit menu's key equivalents**. With no main menu installed, ⌘C, ⌘V, ⌘X,
/// ⌘A and ⌘Z never reach the focused text view, and text input in the panel
/// silently behaves as though the clipboard does not exist.
///
/// String selectors rather than `#selector`: `cut:`/`copy:`/`paste:` are
/// responder-chain conventions implemented by many unrelated classes, and
/// naming one of them (`NSText.copy(_:)`) both reads as a specific dependency
/// and collides with `NSObject.copy()`.
@MainActor
enum MainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(editMenuItem())
        return main
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Peek")

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(AppDelegate.openSettingsFromMenu(_:)),
                                  keyEquivalent: ",")
        // nil target routes through the responder chain to the app delegate,
        // so the item stays live regardless of which window is key.
        settings.target = nil
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(AppDelegate.checkForUpdatesFromMenu(_:)),
                                 keyEquivalent: "")
        updates.target = nil
        menu.addItem(updates)

        menu.addItem(.separator())

        // ⌘Q hides rather than quits. Peek is a resident utility: quitting it
        // by reflex from a window would silently disable the global shortcut
        // and the Services entry. The menu bar item keeps a real Quit, and the
        // title says "Hide" so the binding is not a lie about what it does.
        let hide = NSMenuItem(title: "Hide Peek",
                              action: #selector(AppDelegate.hideToMenuBar(_:)),
                              keyEquivalent: "q")
        hide.target = nil
        menu.addItem(hide)

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        func add(_ title: String, _ selector: String, _ key: String,
                 modifiers: NSEvent.ModifierFlags = .command) {
            let entry = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            menu.addItem(entry)
        }

        add("Undo", "undo:", "z")
        add("Redo", "redo:", "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add("Cut", "cut:", "x")
        add("Copy", "copy:", "c")
        add("Paste", "paste:", "v")
        add("Select All", "selectAll:", "a")

        item.submenu = menu
        return item
    }
}
