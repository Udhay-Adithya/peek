import AppKit
import OSLog

/// Exposes "Ask Peek" in every app's Services and right-click menus.
///
/// The most reliable context path in the product, and the cheapest: macOS
/// hands over the selected text on the pasteboard, so it needs **no
/// Accessibility permission, no event tap and no synthetic keystrokes**, and it
/// works in apps whose accessibility support is absent — including the Electron
/// and Gecko apps that defeat every other approach. Users can also bind their
/// own keyboard shortcut to it in System Settings.
@MainActor
final class ServicesProvider: NSObject {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "services")

    /// Invoked with text the user selected in another application.
    private let onSelection: (String, String?) -> Void

    init(onSelection: @escaping (String, String?) -> Void) {
        self.onSelection = onSelection
        super.init()
    }

    /// Registers as the services provider.
    ///
    /// `NSUpdateDynamicServices` is needed because macOS caches the service
    /// registry; without it a freshly built app's entry can take a long time
    /// to appear. The app must also be in a location Launch Services knows
    /// about, which for development means copying it to /Applications.
    func register() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        Self.logger.debug("services provider registered")
    }

    /// Declared by the `NSMessage` key in Info.plist.
    ///
    /// The selector shape is fixed by AppKit: pasteboard, user data, and an
    /// out-parameter for an error string.
    @objc func askPeek(_ pasteboard: NSPasteboard,
                       userData: String?,
                       error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "No text was selected." as NSString
            return
        }

        // The requesting app is still frontmost at this point.
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Length only — the selection itself is user data.
        Self.logger.debug("service invoked chars=\(text.count, privacy: .public)")
        onSelection(text, sourceApp)
    }
}
