import Foundation
import Observation

/// Which page the expanded window is showing.
///
/// Shared state rather than a parameter, so any entry point — the panel's gear,
/// the menu bar, ⌘, — can put the window on the right page before it appears.
@MainActor
@Observable
final class MainWindowRouter {

    enum Pane: Hashable {
        case conversations
        case settings
    }

    var pane: Pane = .conversations
}
