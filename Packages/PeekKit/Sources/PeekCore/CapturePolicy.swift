import Foundation

/// Decides what Peek is allowed to read, and trims what it does read.
///
/// Selected text is sensitive by default. The policy is deliberately
/// conservative: an app on the deny list is never queried at all, so no
/// credential ever enters Peek's address space, rather than being read and then
/// discarded.
public struct CapturePolicy: Sendable, Equatable {

    /// Apps whose contents are never read.
    ///
    /// Password managers and the system Passwords app hold nothing a user could
    /// want to ask an assistant about, and everything they hold is a
    /// credential. Users can extend this in settings; they cannot shrink it
    /// below the built-in set without an explicit override.
    public static let defaultDeniedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "com.dashlane.Dashlane",
        "org.keepassxc.keepassxc",
        "com.apple.Terminal.SecureInput",
    ]

    public var deniedBundleIDs: Set<String>

    /// Upper bound on captured characters.
    ///
    /// Guards cost and latency: a stray ⌘A in a large document would otherwise
    /// send an entire book to the provider on a single keystroke.
    public var maxCharacters: Int

    public init(deniedBundleIDs: Set<String> = CapturePolicy.defaultDeniedBundleIDs,
                maxCharacters: Int = 8_000) {
        self.deniedBundleIDs = deniedBundleIDs
        self.maxCharacters = maxCharacters
    }

    public func allowsCapture(fromBundleID bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !deniedBundleIDs.contains(bundleID)
    }

    /// Normalises raw selected text.
    /// - Returns: `nil` when the selection carries no usable content.
    public func sanitize(_ raw: String) -> (text: String, wasTruncated: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard trimmed.count > maxCharacters else { return (trimmed, false) }
        let clipped = String(trimmed.prefix(maxCharacters))
        return (clipped, true)
    }
}
