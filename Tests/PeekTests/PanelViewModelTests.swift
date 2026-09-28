import Testing
import Foundation
import PeekCore
@testable import Peek

@Suite("PanelViewModel capture cascade")
@MainActor
struct PanelViewModelTests {

    private func makeModel(
        accessibility: SelectionOutcome,
        clipboard: SelectionOutcome = .empty(appName: "Notes"),
        clipboardEnabled: Bool = true,
        continueRecent: Bool = false,
        autoSend: Bool = false,
        store: RecordingStore = RecordingStore()
    ) -> (PanelViewModel, StubClipboardCapture, AppSettings) {
        let settings = makeTestSettings()
        settings.clipboardFallbackEnabled = clipboardEnabled
        settings.continueRecentConversation = continueRecent
        settings.autoSendOnInvoke = autoSend

        let engine = StubEngine(provider: StubProvider(
            events: [.textDelta("answer"), .finished(.stop)], failure: nil, recorder: nil
        ))
        let session = AssistantSession(engine: engine, store: store)
        let history = HistoryViewModel(store: store)
        let clipboardStub = StubClipboardCapture(outcome: clipboard)

        let model = PanelViewModel(
            settings: settings,
            engine: engine,
            store: store,
            session: session,
            history: history,
            capture: StubSelectionCapture(outcome: accessibility),
            clipboardCapture: clipboardStub
        )
        return (model, clipboardStub, settings)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Cascade

    @Test("uses the Accessibility result and never touches the clipboard")
    func prefersAccessibility() async {
        let context = SelectionContext(text: "obtund", sourceAppName: "Notes")
        let (model, clipboard, _) = makeModel(accessibility: .captured(context))

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.activeContext != nil }

        #expect(model.activeContext?.text == "obtund")
        // The fallback mutates the pasteboard; it must not run speculatively.
        #expect(clipboard.callCount == 0)
    }

    @Test("falls back to the clipboard only when the app exposes nothing")
    func fallsBackWhenUnsupported() async {
        let copied = SelectionContext(text: "from clipboard", sourceAppName: "Obsidian")
        let (model, clipboard, _) = makeModel(
            accessibility: .unsupported(appName: "Obsidian"),
            clipboard: .captured(copied)
        )

        model.refreshContext(frontApp: .stub(name: "Obsidian", bundleID: "md.obsidian"))
        await waitUntil { model.activeContext != nil }

        #expect(model.activeContext?.text == "from clipboard")
        #expect(clipboard.callCount == 1)
    }

    @Test("does not fall back when the user turned it off")
    func respectsFallbackSetting() async {
        let (model, clipboard, _) = makeModel(
            accessibility: .unsupported(appName: "Zen"),
            clipboard: .captured(SelectionContext(text: "should not appear")),
            clipboardEnabled: false
        )

        model.refreshContext(frontApp: .stub(name: "Zen", bundleID: "app.zen-browser.zen"))
        await waitUntil { model.selection != nil }

        #expect(clipboard.callCount == 0)
        #expect(model.activeContext == nil)
    }

    @Test("does not fall back for an empty selection")
    func noFallbackOnEmptySelection() async {
        // The app supports selections and had none; copying would produce
        // whatever unrelated thing was last selected.
        let (model, clipboard, _) = makeModel(accessibility: .empty(appName: "Notes"))

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.selection != nil }

        #expect(clipboard.callCount == 0)
    }

    @Test("does not fall back for a withheld app")
    func noFallbackWhenWithheld() async {
        // Deny-listed apps must never be read by any route.
        let (model, clipboard, _) = makeModel(accessibility: .withheld(appName: "1Password"))

        model.refreshContext(frontApp: .stub(name: "1Password", bundleID: "com.1password.1password"))
        await waitUntil { model.selection != nil }

        #expect(clipboard.callCount == 0)
        #expect(model.activeContext == nil)
    }

    @Test("surfaces a missing permission without attempting a fallback")
    func permissionRequiredIsTerminal() async {
        let (model, clipboard, _) = makeModel(accessibility: .permissionRequired)

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.selection != nil }

        #expect(model.selection == .permissionRequired)
        #expect(clipboard.callCount == 0)
    }

    // MARK: - Context dismissal

    @Test("dismissing context removes it from the next send")
    func dismissingContextDropsIt() async {
        let context = SelectionContext(text: "obtund", sourceAppName: "Notes")
        let (model, _, _) = makeModel(accessibility: .captured(context))

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.activeContext != nil }

        model.dismissContext()
        #expect(model.activeContext == nil)
        // Still not sendable on context alone once dismissed.
        #expect(model.canSend == false)
    }

    @Test("a selection alone is enough to send; nothing at all is not")
    func canSendRules() async {
        let (model, _, _) = makeModel(accessibility: .captured(
            SelectionContext(text: "obtund", sourceAppName: "Notes")
        ))
        #expect(model.canSend == false)

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.activeContext != nil }
        #expect(model.canSend)
    }

    // MARK: - Auto-send

    @Test("does not send automatically by default")
    func autoSendOffByDefault() async {
        let (model, _, _) = makeModel(accessibility: .captured(
            SelectionContext(text: "obtund", sourceAppName: "Notes")
        ))

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.activeContext != nil }
        try? await Task.sleep(for: .milliseconds(60))

        // Sending on every invocation would spend tokens on a misfire.
        #expect(model.session.isEmpty)
    }

    @Test("sends automatically when the user opted in")
    func autoSendWhenEnabled() async {
        let (model, _, _) = makeModel(
            accessibility: .captured(SelectionContext(text: "obtund", sourceAppName: "Notes")),
            autoSend: true
        )

        model.refreshContext(frontApp: .stub())
        await waitUntil { !model.session.isEmpty }
        #expect(model.session.messages.isEmpty == false)
    }

    @Test("does not auto-send when there is no context")
    func noAutoSendWithoutContext() async {
        let (model, _, _) = makeModel(accessibility: .unsupported(appName: "Zen"),
                                      clipboard: .empty(appName: "Zen"),
                                      autoSend: true)

        model.refreshContext(frontApp: .stub(name: "Zen"))
        await waitUntil { model.selection != nil }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.session.isEmpty)
    }

    // MARK: - Conversation continuation

    @Test("continues a recent conversation from the same app")
    func continuesSameApp() async {
        let store = RecordingStore()
        _ = try! await store.seedRecent(title: "earlier", sourceAppName: "Notes")

        let (model, _, _) = makeModel(
            accessibility: .captured(SelectionContext(text: "follow up", sourceAppName: "Notes")),
            continueRecent: true,
            store: store
        )

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.didContinueConversation }
        #expect(model.session.messages.map(\.text) == ["earlier question", "earlier answer"])
    }

    @Test("does not continue a conversation from a different app")
    func doesNotContinueAcrossApps() async {
        // Otherwise an unrelated question lands in the wrong thread.
        let store = RecordingStore()
        _ = try! await store.seedRecent(title: "earlier", sourceAppName: "Safari")

        let (model, _, _) = makeModel(
            accessibility: .captured(SelectionContext(text: "new thing", sourceAppName: "Notes")),
            continueRecent: true,
            store: store
        )

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.selection != nil }
        try? await Task.sleep(for: .milliseconds(80))

        #expect(model.didContinueConversation == false)
        #expect(model.session.isEmpty)
    }

    @Test("does not continue when the setting is off")
    func respectsContinuationSetting() async {
        let store = RecordingStore()
        _ = try! await store.seedRecent(title: "earlier", sourceAppName: "Notes")

        let (model, _, _) = makeModel(
            accessibility: .captured(SelectionContext(text: "x", sourceAppName: "Notes")),
            continueRecent: false,
            store: store
        )

        model.refreshContext(frontApp: .stub())
        await waitUntil { model.selection != nil }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.didContinueConversation == false)
    }

    @Test("new conversation clears context flags and attachments")
    func newConversationResets() async {
        let (model, _, _) = makeModel(accessibility: .captured(
            SelectionContext(text: "obtund", sourceAppName: "Notes")
        ))
        model.refreshContext(frontApp: .stub())
        await waitUntil { model.activeContext != nil }

        model.newConversation()
        #expect(model.didContinueConversation == false)
        #expect(model.attachments.isEmpty)
        #expect(model.session.isEmpty)
    }
}

@Suite("PanelViewModel screen reading")
@MainActor
struct PanelViewModelScreenReadingTests {

    private func makeModel(accessibility: SelectionOutcome,
                           clipboard: SelectionOutcome) -> PanelViewModel {
        let settings = makeTestSettings()
        settings.clipboardFallbackEnabled = true
        settings.continueRecentConversation = false
        settings.autoSendOnInvoke = false

        let store = RecordingStore()
        let engine = StubEngine(provider: StubProvider(events: [], failure: nil, recorder: nil))
        return PanelViewModel(
            settings: settings,
            engine: engine,
            store: store,
            session: AssistantSession(engine: engine, store: store),
            history: HistoryViewModel(store: store),
            capture: StubSelectionCapture(outcome: accessibility),
            clipboardCapture: StubClipboardCapture(outcome: clipboard)
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("offers to read the screen only when the app exposes nothing")
    func offersOnlyWhenUnsupported() async {
        let model = makeModel(accessibility: .unsupported(appName: "Preview"),
                              clipboard: .empty(appName: "Preview"))
        model.refreshContext(frontApp: .stub(name: "Preview"))
        await waitUntil { model.selection != nil }
        #expect(model.canReadFromScreen)
    }

    @Test("does not offer after an empty selection")
    func noOfferWhenSelectionEmpty() async {
        // The app supports selections and had none. Reading the screen would
        // capture something the user did not select.
        let model = makeModel(accessibility: .empty(appName: "Notes"),
                              clipboard: .empty(appName: "Notes"))
        model.refreshContext(frontApp: .stub())
        await waitUntil { model.selection != nil }
        #expect(model.canReadFromScreen == false)
    }

    @Test("does not offer for a withheld app")
    func noOfferWhenWithheld() async {
        // Offering OCR here would invite screenshotting a password manager.
        let model = makeModel(accessibility: .withheld(appName: "1Password"),
                              clipboard: .empty(appName: "1Password"))
        model.refreshContext(frontApp: .stub(name: "1Password",
                                             bundleID: "com.1password.1password"))
        await waitUntil { model.selection != nil }
        #expect(model.canReadFromScreen == false)
    }

    @Test("does not offer when the permission is the problem")
    func noOfferWhenPermissionMissing() async {
        let model = makeModel(accessibility: .permissionRequired,
                              clipboard: .empty(appName: nil))
        model.refreshContext(frontApp: .stub())
        await waitUntil { model.selection != nil }
        #expect(model.canReadFromScreen == false)
    }

    @Test("a successful capture leaves nothing to read")
    func noOfferWhenCaptured() async {
        let model = makeModel(
            accessibility: .captured(SelectionContext(text: "obtund", sourceAppName: "Notes")),
            clipboard: .empty(appName: "Notes")
        )
        model.refreshContext(frontApp: .stub())
        await waitUntil { model.activeContext != nil }
        #expect(model.canReadFromScreen == false)
    }

    @Test("a new invocation clears the screen-reading state")
    func invocationResetsState() async {
        let model = makeModel(accessibility: .unsupported(appName: "Preview"),
                              clipboard: .empty(appName: "Preview"))
        model.refreshContext(frontApp: .stub(name: "Preview"))
        await waitUntil { model.selection != nil }

        model.prepareForInvocation()
        #expect(model.recognizedFromScreen == false)
        #expect(model.recognitionError == nil)
    }
}
