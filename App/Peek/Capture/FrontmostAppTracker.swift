import AppKit
import OSLog

/// Remembers which application the user was actually working in.
///
/// `NSWorkspace.frontmostApplication` answers "who is frontmost *now*", which
/// is the wrong question at every moment Peek needs the answer. By the time a
/// Services handler runs, macOS has already activated Peek to deliver the
/// message, so asking then reports Peek — and a rewrite written back on that
/// basis lands in Peek's own panel instead of the user's document.
///
/// Observing activations instead means the answer is recorded *before* Peek
/// enters the picture, and Peek's own activations are ignored.
@MainActor
final class FrontmostAppTracker {

    private static let logger = Logger(subsystem: "com.udhayadithya.Peek", category: "frontmost")

    private(set) var lastExternalApp: FrontmostApp?
    private var observer: NSObjectProtocol?
    private let ownBundleID: String?

    init(ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.ownBundleID = ownBundleID

        // Seed from the current state, so a service invoked before any
        // activation has been observed still has an answer.
        if let current = FrontmostApp.current(), !isOwnApp(current) {
            lastExternalApp = current
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Read out of the notification here: `Notification` is not
            // Sendable and must not cross into the isolated closure.
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let candidate = FrontmostApp(name: app.localizedName,
                                         bundleID: app.bundleIdentifier,
                                         processID: app.processIdentifier)
            MainActor.assumeIsolated {
                self?.handleActivation(candidate)
            }
        }
    }

    private func handleActivation(_ candidate: FrontmostApp) {
        guard !isOwnApp(candidate) else { return }

        lastExternalApp = candidate
        Self.logger.debug("frontmost app is now \(candidate.bundleID ?? "unknown", privacy: .public)")
    }

    private func isOwnApp(_ app: FrontmostApp) -> Bool {
        guard let ownBundleID else { return false }
        return app.bundleID == ownBundleID
    }

    /// The app a capture or write-back should target.
    ///
    /// Prefers the live frontmost application, but never returns Peek: when
    /// Peek is frontmost the user was, by definition, somewhere else a moment
    /// ago, and that is the app they mean.
    func targetApp() -> FrontmostApp? {
        if let current = FrontmostApp.current(), !isOwnApp(current) {
            return current
        }
        return lastExternalApp
    }

    isolated deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
