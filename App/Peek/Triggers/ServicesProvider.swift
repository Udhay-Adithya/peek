import AppKit
import OSLog
import PeekCore

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
    /// Invoked when the user asks for the selection to be rewritten.
    private let onRewrite: (String, RewriteAction, FrontmostApp?) -> Void

    init(onSelection: @escaping (String, String?) -> Void,
         onRewrite: @escaping (String, RewriteAction, FrontmostApp?) -> Void) {
        self.onSelection = onSelection
        self.onRewrite = onRewrite
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

    // MARK: - Rewrite services

    /// One service entry per preset rather than a single entry with a picker.
    ///
    /// Services declare a fixed message, and a menu the user can read is worth
    /// more than one generic item that then asks what they meant. It is also
    /// how the system's own text services are organised.
    @objc func rewriteFixGrammar(_ pasteboard: NSPasteboard,
                                 userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handleRewrite(.fixGrammar, pasteboard: pasteboard, error: error)
    }

    @objc func rewriteImprove(_ pasteboard: NSPasteboard,
                              userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handleRewrite(.improve, pasteboard: pasteboard, error: error)
    }

    @objc func rewriteShorten(_ pasteboard: NSPasteboard,
                              userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        handleRewrite(.shorten, pasteboard: pasteboard, error: error)
    }

    private func handleRewrite(_ action: RewriteAction,
                               pasteboard: NSPasteboard,
                               error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pasteboard.string(forType: .string),
              RewritePrompt.canRewrite(text) else {
            error?.pointee = "No text was selected." as NSString
            return
        }

        // Captured here, while the requesting app is still frontmost — the
        // write-back needs its pid, and Peek's panel is about to take focus.
        let frontApp = FrontmostApp.current()

        Self.logger.debug("rewrite service invoked action=\(action.title, privacy: .public) chars=\(text.count, privacy: .public)")
        onRewrite(text, action, frontApp)
    }
}
