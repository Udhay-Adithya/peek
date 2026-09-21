import Foundation
import CoreGraphics

/// What the user was looking at when they invoked Peek.
public struct SelectionContext: Sendable, Equatable {
    /// The selected text, already sanitised by ``CapturePolicy``.
    public let text: String
    /// Display name of the app the selection came from, for the context chip.
    public let sourceAppName: String?
    public let sourceBundleID: String?
    /// On-screen bounds of the selection in AppKit coordinates, when the app
    /// exposes them. Lets the panel anchor to the text itself rather than the
    /// pointer, which is what the system Look Up card does.
    public let selectionBounds: CGRect?
    /// True when the text was truncated to fit ``CapturePolicy/maxCharacters``.
    public let wasTruncated: Bool

    public init(text: String,
                sourceAppName: String? = nil,
                sourceBundleID: String? = nil,
                selectionBounds: CGRect? = nil,
                wasTruncated: Bool = false) {
        self.text = text
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.selectionBounds = selectionBounds
        self.wasTruncated = wasTruncated
    }
}

/// The result of attempting to read the user's selection.
///
/// Modelled as distinct cases rather than an optional because each one needs a
/// different response in the UI: a missing permission is recoverable and worth
/// explaining, an app that exposes nothing is not the user's fault and should
/// not nag, and a deny-listed app must never be retried.
public enum SelectionOutcome: Sendable, Equatable {
    case captured(SelectionContext)
    /// Accessibility has not been granted. Recoverable — offer the settings link.
    case permissionRequired
    /// The app exposes no selection API (Electron without AXManualAccessibility,
    /// some Java and Catalyst apps, certain PDF views).
    case unsupported(appName: String?)
    /// The app exposed a selection API but nothing was selected.
    case empty(appName: String?)
    /// Capture was refused on privacy grounds — deny-listed app or secure field.
    case withheld(appName: String?)
}
