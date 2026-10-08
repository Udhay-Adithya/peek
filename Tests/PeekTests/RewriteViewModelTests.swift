import Testing
import AppKit
import Foundation
import PeekCore
@testable import Peek

/// Records what was written without touching a real app.
@MainActor
final class StubWriterProbe {
    private(set) var written: [String] = []
    var failure: SelectionWriter.Failure?
}

@Suite("RewriteViewModel")
@MainActor
struct RewriteViewModelTests {

    private func makeModel(
        original: String = "teh quick brown fox",
        action: RewriteAction = .fixGrammar,
        events: [AssistantStreamEvent] = [.textDelta("the quick brown fox"), .finished(.stop)],
        failure: Error? = nil
    ) -> (RewriteViewModel, RequestLog) {
        let log = RequestLog()
        let engine = StubEngine(provider: StubProvider(events: events,
                                                       failure: failure,
                                                       recorder: log))
        let model = RewriteViewModel(original: original,
                                     action: action,
                                     frontApp: .stub(),
                                     engine: engine)
        return (model, log)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("streams a proposal and reaches the decision point")
    func producesProposal() async {
        let (model, _) = makeModel()
        model.run()
        await waitUntil { model.phase == .proposed }

        #expect(model.proposed == "the quick brown fox")
        #expect(model.canReplace)
    }

    @Test("keeps the original text for the whole lifetime")
    func retainsOriginal() async {
        let (model, _) = makeModel()
        model.run()
        await waitUntil { model.phase == .proposed }
        // The original is the user's work; it must never be derived from the
        // proposal or re-read from the app.
        #expect(model.original == "teh quick brown fox")
    }

    @Test("sends the rewrite prompt, not a conversational one")
    func usesRewritePrompt() async {
        let (model, log) = makeModel()
        model.run()
        await waitUntil { model.phase == .proposed }

        let request = await log.last
        #expect(request?.systemInstruction == RewritePrompt.systemInstruction)
        #expect(request?.temperature == 0.2)
        #expect(request?.messages.first?.plainText.contains("teh quick brown fox") == true)
    }

    @Test("strips a code fence the model added anyway")
    func cleansWrappedOutput() async {
        let (model, _) = makeModel(events: [
            .textDelta("```\nthe quick brown fox\n```"), .finished(.stop),
        ])
        model.run()
        await waitUntil { model.phase == .proposed }
        // Otherwise the fence would be written into the user's document.
        #expect(model.proposed == "the quick brown fox")
    }

    @Test("reports an unchanged result instead of offering a no-op replace")
    func detectsNoChange() async {
        let (model, _) = makeModel(original: "already fine",
                                   events: [.textDelta("already fine"), .finished(.stop)])
        model.run()
        await waitUntil { model.phase == .proposed }

        #expect(model.isUnchanged)
        #expect(model.canReplace == false)
    }

    @Test("refuses to replace with nothing")
    func refusesEmptyProposal() async {
        let (model, _) = makeModel(events: [.finished(.stop)])
        model.run()
        await waitUntil { if case .failed = model.phase { return true }; return false }
        #expect(model.canReplace == false)
    }

    @Test("surfaces a provider failure without losing the original")
    func surfacesFailure() async {
        let (model, _) = makeModel(events: [], failure: AssistantError.unauthorized)
        model.run()
        await waitUntil { if case .failed = model.phase { return true }; return false }

        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failed phase")
            return
        }
        #expect(message.contains("rejected"))
        #expect(model.original == "teh quick brown fox")
    }

    @Test("cannot replace while still running")
    func noReplaceWhileRunning() async {
        let (model, _) = makeModel()
        model.run()
        // Before the stream resolves there is nothing to accept.
        #expect(model.canReplace == false)
    }

    @Test("changing the action re-runs against the same original")
    func changingActionReruns() async {
        let (model, log) = makeModel()
        model.run()
        await waitUntil { model.phase == .proposed }

        model.change(to: .shorten)
        await waitUntil { model.phase == .proposed }

        #expect(model.action == .shorten)
        let request = await log.last
        #expect(request?.messages.first?.plainText.contains(RewriteAction.shorten.instruction) == true)
        #expect(request?.messages.first?.plainText.contains("teh quick brown fox") == true)
    }

    @Test("copying the original puts it on the clipboard")
    func copyOriginalWorks() async {
        let (model, _) = makeModel()
        model.run()
        await waitUntil { model.phase == .proposed }

        model.copyOriginal()
        #expect(model.didCopyOriginal)
        // This is the recovery path offered after a replace, since neither
        // write route participates in the app's undo stack.
        #expect(NSPasteboard.general.string(forType: .string) == "teh quick brown fox")
    }
}

@Suite("RewriteAction service coverage")
struct RewriteServiceCoverageTests {

    @Test("every preset has a matching Info.plist service entry")
    func presetsHaveServices() throws {
        // A preset with no service entry is unreachable; an entry with no
        // handler crashes when chosen. Both are easy to half-add.
        // Read through the loaded bundle's info dictionary rather than as a
        // resource file: Info.plist is the bundle's metadata, not something
        // copied into Resources.
        let bundle = Bundle(for: AppDelegate.self)
        let services = try #require(
            bundle.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]]
        )
        let messages = Set(services.compactMap { $0["NSMessage"] as? String })

        #expect(messages.contains("askPeek"))
        #expect(messages.contains("rewriteFixGrammar"))
        #expect(messages.contains("rewriteImprove"))
        #expect(messages.contains("rewriteShorten"))
        #expect(messages.count == RewriteAction.presets.count + 1)
    }
}

@Suite("ServicesAvailability")
struct ServicesAvailabilityTests {

    private func status(message: String,
                        servicesMenu: Bool,
                        contextMenu: Bool) -> [String: Any] {
        [
            "com.udhayadithya.Peek - Some Title - \(message)": [
                "enabled_services_menu": NSNumber(value: servicesMenu),
                "enabled_context_menu": NSNumber(value: contextMenu),
            ],
        ]
    }

    @Test("an absent entry counts as disabled, because that is the macOS default")
    func absentMeansDisabled() {
        // This is the case that made the feature look broken: nothing is
        // written to the pbs domain until the user touches the checkbox, and
        // the default behind that absence is off.
        #expect(ServicesAvailability.isEnabled(message: "askPeek", in: [:]) == false)
    }

    @Test("reads an enabled service")
    func readsEnabled() {
        let dictionary = status(message: "askPeek", servicesMenu: true, contextMenu: true)
        #expect(ServicesAvailability.isEnabled(message: "askPeek", in: dictionary))
    }

    @Test("either presentation counts as enabled")
    func eitherPresentationCounts() {
        // The context menu is where most people actually reach for it.
        let contextOnly = status(message: "askPeek", servicesMenu: false, contextMenu: true)
        #expect(ServicesAvailability.isEnabled(message: "askPeek", in: contextOnly))

        let menuOnly = status(message: "askPeek", servicesMenu: true, contextMenu: false)
        #expect(ServicesAvailability.isEnabled(message: "askPeek", in: menuOnly))
    }

    @Test("an explicitly disabled service reads as disabled")
    func readsDisabled() {
        let dictionary = status(message: "askPeek", servicesMenu: false, contextMenu: false)
        #expect(ServicesAvailability.isEnabled(message: "askPeek", in: dictionary) == false)
    }

    @Test("matches on the message, not the user-visible title")
    func matchesOnMessage() {
        // Titles are display text that can be localised or reworded; the
        // message is the stable identifier.
        let dictionary = [
            "com.udhayadithya.Peek - Completely Different Wording - rewriteShorten": [
                "enabled_services_menu": NSNumber(value: true),
            ],
        ] as [String: Any]
        #expect(ServicesAvailability.isEnabled(message: "rewriteShorten", in: dictionary))
    }

    @Test("does not confuse one service for another with a shared prefix")
    func doesNotMatchPrefixes() {
        // "rewrite" must not satisfy a lookup for "rewriteShorten".
        let dictionary = status(message: "rewrite", servicesMenu: true, contextMenu: true)
        #expect(ServicesAvailability.isEnabled(message: "rewriteShorten", in: dictionary) == false)
    }

    @Test("reports every declared service from the bundle")
    func reportsDeclaredServices() {
        let entries = ServicesAvailability.entries()
        #expect(entries.count == RewriteAction.presets.count + 1)
        #expect(entries.contains { $0.message == "askPeek" })
        #expect(entries.allSatisfy { !$0.title.isEmpty })
    }
}
