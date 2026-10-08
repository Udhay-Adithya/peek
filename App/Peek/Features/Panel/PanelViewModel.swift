import AppKit
import Observation
import PeekCore
import PeekPersistence

/// State behind the floating panel.
@MainActor
@Observable
final class PanelViewModel {

    /// Result of the most recent context capture. `nil` before the first one.
    private(set) var selection: SelectionOutcome?
    private(set) var isCapturing = false

    /// Set when the user dismisses the context chip, so a re-capture does not
    /// silently bring back context they explicitly removed.
    private(set) var contextDismissed = false

    var prompt: String = ""

    /// Pending screenshot attachments for the next turn.
    ///
    /// Only the encoded JPEG bytes plus a small preview are retained — never a
    /// full-resolution `CGImage`, which for a 6K display would be tens of
    /// megabytes held for as long as the panel is open.
    private(set) var attachments: [PendingAttachment] = []
    private(set) var isCapturingScreenshot = false
    private(set) var screenshotError: String?

    /// Text recognition state, kept separate from screenshot state: one is
    /// reading the screen for context, the other is attaching a picture.
    private(set) var isRecognizingText = false
    private(set) var recognitionError: String?
    /// Set when the current context came from OCR rather than a selection, so
    /// the transcript can say where the text came from.
    private(set) var recognizedFromScreen = false

    /// Remembered so OCR context can be attributed to the app the user was in,
    /// rather than to whatever became frontmost during region selection.
    private var lastFrontAppName: String?

    /// Whether the Accessibility layer reported this app as exposing no
    /// selection API at all, before the clipboard fallback had its turn.
    private var accessibilityReportedUnsupported = false

    struct PendingAttachment: Identifiable, Sendable {
        let id = UUID()
        let attachment: ImageAttachment
        let preview: NSImage?

        var byteCount: Int { attachment.byteCount }
    }

    /// Shared with the expanded window, so "expand" continues the same
    /// conversation rather than starting a second one.
    let session: AssistantSession

    private let capture: any SelectionCapturing
    private let clipboardCapture: any ClipboardCapturing
    private let screenshots = ScreenshotService()
    private let recognizer = VisionTextRecognizer()
    private let settings: AppSettings
    private let engine: any ProviderResolving
    private var captureTask: Task<Void, Never>?

    /// Invoked when the user asks for settings from inside the panel.
    var onOpenSettings: (() -> Void)?
    /// Invoked when the user asks to browse conversation history.
    var onShowHistoryInWindow: (() -> Void)?
    /// Used to get the panel out of the way of a region capture.
    var onRequestHidePanel: (() -> Void)?
    var onRequestShowPanel: (() -> Void)?

    let history: HistoryViewModel

    /// Whether the history list is showing.
    var isShowingHistory = false

    /// Set when the panel resumed an existing conversation on invocation.
    private(set) var didContinueConversation = false

    private let store: ConversationStore

    /// Invoked when the user expands the panel into the full window.
    var onExpand: (() -> Void)?

    init(settings: AppSettings,
         engine: any ProviderResolving,
         store: ConversationStore,
         session: AssistantSession,
         history: HistoryViewModel,
         capture: any SelectionCapturing = AccessibilitySelectionCapture(),
         clipboardCapture: any ClipboardCapturing = ClipboardSelectionCapture()) {
        self.settings = settings
        self.engine = engine
        self.store = store
        self.capture = capture
        self.clipboardCapture = clipboardCapture
        self.session = session
        self.history = history
    }

    func expand() {
        onExpand?()
    }

    /// Resumes a recent conversation when the invocation plausibly belongs to it.
    ///
    /// Conditions are deliberately narrow — same source app, inside the time
    /// window, and nothing already on screen. Anything looser and unrelated
    /// questions accumulate into one unusable thread, which is the failure mode
    /// this feature invites.
    private func continueRecentConversationIfAppropriate(sourceAppName: String?) async {
        guard settings.continueRecentConversation,
              session.isEmpty,
              session.conversationID == nil else { return }

        do {
            guard let candidate = try await store.mostRecentConversation(
                updatedWithin: AppSettings.continuationWindow
            ) else { return }
            guard candidate.sourceAppName == sourceAppName else { return }

            await session.load(candidate.id)
            didContinueConversation = true
        } catch {
            // Continuation is a convenience; failing it must be silent.
        }
    }

    /// Opens conversation search in the full window rather than a sheet.
    ///
    /// Browsing history is a task with room to breathe; a 440pt panel is the
    /// wrong surface for it.
    func showHistory() {
        history.refresh()
        onShowHistoryInWindow?()
    }

    /// Begins a fresh conversation for a new invocation.
    ///
    /// Every invocation starts clean unless continuation is explicitly enabled:
    /// re-opening the panel onto the tail of an unrelated earlier conversation
    /// is disorienting, and it silently feeds that history to the model.
    func prepareForInvocation() {
        guard !session.isStreaming else { return }
        session.reset()
        prompt = ""
        attachments.removeAll()
        screenshotError = nil
        recognitionError = nil
        recognizedFromScreen = false
        didContinueConversation = false
    }

    func openConversation(_ id: ConversationID) {
        isShowingHistory = false
        Task { await session.load(id) }
    }

    // MARK: - Reading from the screen

    /// Whether offering to read the screen makes sense right now.
    ///
    /// Keyed on what *Accessibility* reported, not on the final outcome. The
    /// clipboard fallback turns an unsupported app into `.empty` when the
    /// synthetic copy yields nothing, which is indistinguishable from an app
    /// that supports selections and simply had none — and those two cases want
    /// opposite answers. A withheld app is never offered OCR, since that would
    /// amount to inviting the user to screenshot their password manager.
    var canReadFromScreen: Bool {
        guard accessibilityReportedUnsupported else { return false }
        switch selection {
        case .unsupported, .empty: return true
        default:                   return false
        }
    }

    /// Lets the user drag out a region, then reads its text locally.
    ///
    /// Deliberately an explicit action rather than an automatic fallback.
    /// Recognising the whole screen would supply a wall of unrelated text as
    /// "context" — the toolbar, the sidebar, whatever is behind the window —
    /// and Peek cannot know which part the user meant. Dragging a region is the
    /// user saying exactly that.
    func readFromScreen() {
        guard !isRecognizingText else { return }
        isRecognizingText = true
        recognitionError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRecognizingText = false }

            guard ScreenRecordingPermission.isGranted else {
                ScreenRecordingPermission.request()
                self.recognitionError = "Grant Screen Recording in System Settings, then try again."
                return
            }

            // The panel would otherwise sit over the region being selected.
            self.onRequestHidePanel?()
            let rect = await RegionSelectionOverlay().presentAndWaitForSelection()
            self.onRequestShowPanel?()

            guard let rect else { return }   // cancelled

            do {
                let image = try await self.screenshots.captureRegionForRecognition(rect)
                guard let recognized = try await self.recognizer.recognizeText(in: image) else {
                    self.recognitionError = "No readable text in that region."
                    return
                }
                guard let sanitized = CapturePolicy().sanitize(recognized.text) else {
                    self.recognitionError = "No readable text in that region."
                    return
                }

                self.contextDismissed = false
                self.selection = .captured(SelectionContext(
                    text: sanitized.text,
                    sourceAppName: self.lastFrontAppName,
                    sourceBundleID: nil,
                    selectionBounds: nil,
                    wasTruncated: sanitized.wasTruncated
                ))
                self.recognizedFromScreen = true
            } catch {
                self.recognitionError = error.localizedDescription
            }
        }
    }

    var hasCredentials: Bool { engine.hasCredentials }

    /// The context actually in play, honouring an explicit dismissal.
    var activeContext: SelectionContext? {
        guard !contextDismissed, case .captured(let context) = selection else { return nil }
        return context
    }

    var canSend: Bool {
        PromptComposer.canSend(prompt: prompt,
                               context: activeContext,
                               attachments: attachments.map(\.attachment))
    }

    // MARK: - Screenshots

    /// Captures the whole display. Always an explicit user action.
    func captureScreen() {
        runCapture { service in
            try await service.captureDisplay(containing: NSEvent.mouseLocation)
        }
    }

    /// Lets the user drag out a region, then captures it.
    func captureRegion() {
        guard !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        screenshotError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isCapturingScreenshot = false }

            guard self.ensureScreenRecordingPermission() else { return }

            // The panel would otherwise sit on top of the region the user is
            // trying to select.
            self.onRequestHidePanel?()
            let rect = await RegionSelectionOverlay().presentAndWaitForSelection()
            self.onRequestShowPanel?()

            guard let rect else { return }   // cancelled
            do {
                self.appendAttachment(try await self.screenshots.captureRegion(rect))
            } catch {
                self.screenshotError = error.localizedDescription
            }
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func runCapture(
        _ body: @escaping @MainActor (ScreenshotService) async throws -> ImageAttachment
    ) {
        guard !isCapturingScreenshot else { return }
        isCapturingScreenshot = true
        screenshotError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isCapturingScreenshot = false }
            guard self.ensureScreenRecordingPermission() else { return }
            do {
                self.appendAttachment(try await body(self.screenshots))
            } catch {
                self.screenshotError = error.localizedDescription
            }
        }
    }

    /// Requests Screen Recording only at the point of use.
    private func ensureScreenRecordingPermission() -> Bool {
        guard !ScreenRecordingPermission.isGranted else { return true }
        ScreenRecordingPermission.request()
        screenshotError = "Grant Screen Recording in System Settings, then try again."
        return false
    }

    private func appendAttachment(_ attachment: ImageAttachment) {
        attachments.append(PendingAttachment(
            attachment: attachment,
            preview: NSImage(data: attachment.data)
        ))
    }

    // MARK: - Context

    /// Reads the selection for `frontApp` without blocking the panel.
    ///
    /// The panel is already on screen by the time this runs. Accessibility
    /// calls are synchronous IPC into another process, so they happen off the
    /// main actor and only the resulting value comes back.
    func refreshContext(frontApp: FrontmostApp?) {
        captureTask?.cancel()
        contextDismissed = false
        didContinueConversation = false
        recognizedFromScreen = false
        recognitionError = nil
        accessibilityReportedUnsupported = false
        lastFrontAppName = frontApp?.name
        isCapturing = true

        let capture = self.capture
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0

        captureTask = Task { [weak self] in
            // Task.detached, not a bare `await`: capture must not inherit the
            // main actor. Swift 6.2 is in the middle of changing whether a
            // nonisolated async function runs on the caller's actor, and an
            // Accessibility round-trip on the main actor would stall the panel.
            let outcome = await Task.detached(priority: .userInitiated) {
                await capture.capture(frontApp: frontApp, primaryScreenMaxY: primaryMaxY)
            }.value

            guard !Task.isCancelled, let self else { return }

            // Accessibility is always tried first: it is instantaneous, has no
            // side effects, and gives selection bounds. The clipboard fallback
            // only runs where the app genuinely exposes nothing.
            // Recorded before the fallback runs: it can turn an unsupported app
            // into `.empty`, and only the Accessibility answer distinguishes
            // "this app exposes nothing" from "nothing was selected".
            if case .unsupported = outcome {
                self.accessibilityReportedUnsupported = true
            }

            let final: SelectionOutcome
            if case .unsupported = outcome, self.settings.clipboardFallbackEnabled {
                final = await self.clipboardCapture.capture(frontApp: frontApp)
            } else {
                final = outcome
            }

            guard !Task.isCancelled else { return }
            self.selection = final
            self.isCapturing = false

            if case .captured(let context) = final {
                await self.continueRecentConversationIfAppropriate(
                    sourceAppName: context.sourceAppName
                )
            }
            self.autoSendIfConfigured()
        }
    }

    /// Fires the request immediately, when the user has opted in.
    ///
    /// Gated on an explicit setting, on the conversation being fresh, and on
    /// credentials existing. Sending on every invocation would spend tokens and
    /// ship the selection to a third party on what may have been a misfire.
    private func autoSendIfConfigured() {
        guard settings.autoSendOnInvoke,
              session.isEmpty,
              engine.hasCredentials,
              activeContext != nil else { return }
        send()
    }

    func dismissContext() {
        contextDismissed = true
    }

    /// Accepts a selection handed over by the Services menu.
    ///
    /// Bypasses Accessibility entirely: macOS already supplied the text, so any
    /// in-flight capture is cancelled rather than allowed to overwrite it.
    func presentProvidedSelection(text: String, appName: String?) {
        captureTask?.cancel()
        isCapturing = false
        contextDismissed = false

        guard let sanitized = CapturePolicy().sanitize(text) else {
            selection = .empty(appName: appName)
            return
        }
        selection = .captured(SelectionContext(
            text: sanitized.text,
            sourceAppName: appName,
            sourceBundleID: nil,
            selectionBounds: nil,
            wasTruncated: sanitized.wasTruncated
        ))
        autoSendIfConfigured()
    }

    // MARK: - Sending

    func send() {
        guard canSend, !session.isStreaming else { return }
        let outgoing = prompt
        let outgoingAttachments = attachments.map(\.attachment)
        prompt = ""
        // Released as soon as the turn is dispatched; the request holds the
        // only remaining reference to the bytes.
        attachments.removeAll()
        screenshotError = nil
        session.send(prompt: outgoing, context: activeContext, attachments: outgoingAttachments)
    }

    func newConversation() {
        session.reset()
        didContinueConversation = false
        prompt = ""
        attachments.removeAll()
        screenshotError = nil
    }

    func openSettings() {
        onOpenSettings?()
    }

    // MARK: - Permissions

    func requestAccessibilityPermission() {
        AccessibilityPermission.prompt()
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }
}
