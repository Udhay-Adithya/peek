import Testing
import Foundation
import PeekCore
@testable import Peek

@Suite("HeadlessAssistant")
@MainActor
struct HeadlessAssistantTests {

    private func makeAssistant(
        events: [AssistantStreamEvent] = [.textDelta("a trackpad"), .finished(.stop)],
        failure: Error? = nil,
        store: RecordingStore? = nil
    ) -> (HeadlessAssistant, RequestLog, RecordingStore) {
        let log = RequestLog()
        let backing = store ?? RecordingStore()
        let engine = StubEngine(provider: StubProvider(events: events,
                                                       failure: failure,
                                                       recorder: log))
        return (HeadlessAssistant(engine: engine, store: backing), log, backing)
    }

    @Test("returns the full answer as a single string")
    func returnsAnswer() async throws {
        // An automation wants a value, not a stream.
        let (assistant, _, _) = makeAssistant(events: [
            .textDelta("a "), .textDelta("trackpad"), .finished(.stop),
        ])
        #expect(try await assistant.answer("what is a force touch") == "a trackpad")
    }

    @Test("assembles snapshot streaming too")
    func handlesSnapshots() async throws {
        // The on-device model streams cumulative snapshots.
        let (assistant, _, _) = makeAssistant(events: [
            .textSnapshot("the dog"), .textSnapshot("the cat sat"), .finished(.stop),
        ])
        #expect(try await assistant.answer("x") == "the cat sat")
    }

    @Test("rejects an empty question before calling a provider")
    func rejectsEmptyQuestion() async throws {
        let (assistant, log, _) = makeAssistant()
        await #expect(throws: HeadlessAssistant.Failure.emptyQuestion) {
            _ = try await assistant.answer("   \n ")
        }
        #expect(await log.count == 0)
    }

    @Test("reports an empty answer rather than returning an empty string")
    func reportsEmptyAnswer() async throws {
        // A shortcut receiving "" silently is worse than one that fails.
        let (assistant, _, _) = makeAssistant(events: [.finished(.stop)])
        await #expect(throws: HeadlessAssistant.Failure.emptyAnswer) {
            _ = try await assistant.answer("x")
        }
    }

    @Test("propagates a provider failure")
    func propagatesFailure() async throws {
        let (assistant, _, _) = makeAssistant(events: [],
                                              failure: AssistantError.unauthorized)
        await #expect(throws: AssistantError.unauthorized) {
            _ = try await assistant.answer("x")
        }
    }

    @Test("records the exchange in history")
    func persistsConversation() async throws {
        let (assistant, _, store) = makeAssistant()
        _ = try await assistant.answer("what is a force touch")

        let conversations = try await store.recentConversations(limit: 5)
        #expect(conversations.count == 1)
        // Attributed to Shortcuts so it is distinguishable from a panel
        // conversation when browsing history.
        #expect(conversations.first?.sourceAppName == "Shortcuts")

        let messages = try await store.messages(in: conversations[0].id)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.map(\.text) == ["what is a force touch", "a trackpad"])
    }

    @Test("still answers when history cannot be written")
    func survivesStoreFailure() async throws {
        // An automation that got its answer must not fail because the
        // conversation log could not be updated.
        let engine = StubEngine(provider: StubProvider(
            events: [.textDelta("fine"), .finished(.stop)], failure: nil, recorder: nil
        ))
        let assistant = HeadlessAssistant(engine: engine, store: FailingStore())
        #expect(try await assistant.answer("x") == "fine")
    }

    @Test("works with no store at all")
    func worksWithoutStore() async throws {
        let engine = StubEngine(provider: StubProvider(
            events: [.textDelta("fine"), .finished(.stop)], failure: nil, recorder: nil
        ))
        let assistant = HeadlessAssistant(engine: engine, store: nil)
        #expect(try await assistant.answer("x") == "fine")
    }

    @Test("trims the question before sending it")
    func trimsQuestion() async throws {
        let (assistant, log, _) = makeAssistant()
        _ = try await assistant.answer("  padded question  ")
        #expect(await log.last?.messages.first?.plainText == "padded question")
    }

    @Test("records token usage with the answer")
    func recordsUsage() async throws {
        let (assistant, _, store) = makeAssistant(events: [
            .textDelta("hi"),
            .usage(TokenUsage(inputTokens: 7, outputTokens: 2)),
            .finished(.stop),
        ])
        _ = try await assistant.answer("x")

        let conversations = try await store.recentConversations(limit: 1)
        let messages = try await store.messages(in: conversations[0].id)
        #expect(messages.last?.inputTokens == 7)
        #expect(messages.last?.outputTokens == 2)
    }
}

/// A store whose every write fails.
private actor FailingStore: ConversationStore {
    struct Boom: Error {}

    func createConversation(title: String, providerID: String,
                            modelID: String, sourceAppName: String?) throws -> ConversationID {
        throw Boom()
    }
    func appendMessage(_ message: PersistedMessage, to id: ConversationID) throws { throw Boom() }
    func updateTitle(_ title: String, for id: ConversationID) throws { throw Boom() }
    func deleteConversation(_ id: ConversationID) throws { throw Boom() }
    func recentConversations(limit: Int) throws -> [ConversationSummary] { [] }
    func messages(in id: ConversationID) throws -> [PersistedMessage] { [] }
    func search(_ query: String, limit: Int) throws -> [ConversationSummary] { [] }
    func mostRecentConversation(updatedWithin interval: TimeInterval) throws -> ConversationSummary? { nil }
    func usageStatistics(lastDays days: Int, calendar: Calendar) throws -> UsageStatistics { .empty }
}

@Suite("URL scheme")
struct URLSchemeTests {

    @Test("the peek scheme is registered in the bundle")
    func schemeRegistered() throws {
        // The Control Center extension reaches the app through this; a missing
        // registration makes the control silently do nothing.
        let bundle = Bundle(for: AppDelegate.self)
        let types = try #require(
            bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        #expect(schemes.contains("peek"))
    }

    @Test("the control extension is embedded")
    func extensionEmbedded() throws {
        // WidgetKit loads controls from an appex; if it is not embedded the
        // control never appears, and the app still builds and runs fine.
        let bundle = Bundle(for: AppDelegate.self)
        let plugins = try #require(bundle.builtInPlugInsURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: plugins.path)) ?? []
        #expect(names.contains("PeekControls.appex"))
    }
}

@Suite("Control extension packaging")
struct ControlExtensionTests {

    private var appexURL: URL? {
        Bundle(for: AppDelegate.self).builtInPlugInsURL?
            .appendingPathComponent("PeekControls.appex")
    }

    @Test("the control extension declares the widget extension point")
    func declaresExtensionPoint() throws {
        let url = try #require(appexURL)
        let plist = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try #require(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        let extensionInfo = try #require(parsed["NSExtension"] as? [String: Any])
        #expect(extensionInfo["NSExtensionPointIdentifier"] as? String
                == "com.apple.widgetkit-extension")
    }

    @Test("the control extension is sandboxed")
    func extensionIsSandboxed() throws {
        // macOS refuses to register an unsandboxed app extension, and does so
        // silently: it installs, signs and validates, then never appears in
        // Control Center. The host app cannot be sandboxed (ADR 0002), which
        // makes it tempting to match here — that was the bug.
        let url = try #require(appexURL)
        let entitlements = url.appendingPathComponent("Contents/Resources/PeekControls.entitlements")

        // Read from the source entitlements when present in the built product;
        // otherwise assert via codesign on the signed appex.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        process.waitUntilExit()

        _ = entitlements
        #expect(output.contains("com.apple.security.app-sandbox"))
        // The value must be true; `<false/>` immediately after the key is the
        // failure this guards.
        #expect(output.contains("app-sandbox</key><false/>") == false)
    }
}
