import AppIntents
import SwiftUI
import WidgetKit

/// Peek in Control Center and the menu-bar clock.
///
/// Lives in an extension because WidgetKit loads controls from an appex and
/// cannot see code in the app binary. That boundary is the design constraint
/// here: the extension is a separate process with no access to Peek's engine,
/// Keychain or conversation store.
///
/// Rather than reproduce any of that, the control simply asks the running app
/// to show itself through a URL. Peek is a resident menu-bar app, so it is
/// already there to answer — and the URL scheme is independently useful for
/// scripting.
@main
struct PeekControls: WidgetBundle {
    var body: some Widget {
        ShowPeekControl()
    }
}

struct ShowPeekControl: ControlWidget {

    static let kind = "com.udhayadithya.Peek.ShowPeekControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenPeekIntent()) {
                Label("Ask Peek", systemImage: "text.magnifyingglass")
            }
        }
        .displayName("Ask Peek")
        .description("Open Peek's floating panel.")
    }
}

/// Opens Peek from the control.
///
/// Deliberately does nothing but open a URL. An intent running inside the
/// extension cannot reach the app's state, and inventing a cross-process
/// channel to ask a question from Control Center would be a great deal of
/// machinery for a button whose job is to show a panel the user then types
/// into.
struct OpenPeekIntent: AppIntent {

    static let title: LocalizedStringResource = "Open Peek"
    static let description = IntentDescription("Opens Peek's floating panel.")

    /// The app is already running; this brings its panel up.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "peek://show")!))
    }
}
