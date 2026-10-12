import AppIntents
import Foundation

/// Ask Peek a question from Shortcuts, Spotlight or Siri.
///
/// Returns the answer as a string so it can feed the next step of a shortcut,
/// which is the whole point of exposing this: an automation wants a value, not
/// a window.
struct AskPeekIntent: AppIntent {

    static let title: LocalizedStringResource = "Ask Peek"
    static let description = IntentDescription(
        "Ask Peek a question and get the answer back as text.",
        categoryName: "Assistant",
        searchKeywords: ["ask", "assistant", "question", "ai", "look up"]
    )

    /// Runs without bringing Peek to the front: a shortcut that silently
    /// returns an answer is far more composable than one that steals focus.
    static let openAppWhenRun = false

    @Parameter(title: "Question",
               description: "What to ask Peek.",
               requestValueDialog: "What would you like to ask?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Peek \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let assistant = IntentServices.assistant() else {
            throw HeadlessAssistant.Failure.notConfigured
        }
        let answer = try await assistant.answer(question)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Opens the floating panel.
///
/// The counterpart to ``AskPeekIntent``: useful as the last step of a shortcut
/// that has gathered context and now wants the user to take over.
struct ShowPeekIntent: AppIntent {

    static let title: LocalizedStringResource = "Show Peek"
    static let description = IntentDescription(
        "Open Peek's floating panel.",
        categoryName: "Assistant",
        searchKeywords: ["show", "open", "panel", "peek"]
    )

    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let showPanel = IntentServices.showPanel else {
            throw HeadlessAssistant.Failure.notConfigured
        }
        showPanel()
        return .result()
    }
}

/// Phrases that work without the user building a shortcut first.
struct PeekShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPeekIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "\(.applicationName) what is",
            ],
            shortTitle: "Ask Peek",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: ShowPeekIntent(),
            phrases: [
                "Show \(.applicationName)",
                "Open \(.applicationName)",
            ],
            shortTitle: "Show Peek",
            systemImageName: "macwindow"
        )
    }
}
