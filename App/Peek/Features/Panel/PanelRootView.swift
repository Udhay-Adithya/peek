import SwiftUI
import PeekCore

/// Panel contents: context, transcript and composer.
struct PanelRootView: View {

    @Bindable var model: PanelViewModel
    @FocusState private var promptFocused: Bool
    @State private var composerHeight: CGFloat = 20

    var body: some View {
        Group {
            if let rewrite = model.rewrite {
                RewriteView(model: rewrite) { model.endRewrite() }
            } else {
                assistant
            }
        }
        .onAppear { promptFocused = true }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            transcript
            Divider().opacity(0.5)
            composer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text("Peek")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if model.didContinueConversation {
                // Resuming a thread silently would be surprising; say so.
                Text("continued")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.session.isStreaming {
                Button("Stop") { model.session.cancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(".", modifiers: .command)
            } else if !model.session.isEmpty {
                Button {
                    model.newConversation()
                    promptFocused = true
                } label: {
                    Image(systemName: "plus.bubble")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New conversation (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }

            if model.isCapturing {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }

            Button {
                model.expand()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open in window (\u{2318}\u{21E7}O)")
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .accessibilityLabel("Open in window")

            Button {
                model.showHistory()
            } label: {
                Image(systemName: "clock")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Conversation history (\u{2318}K)")
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Conversation history")

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings (\u{2318},)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    contextArea
                    ForEach(model.session.messages) { message in
                        MessageRow(message: message, onRetry: { model.session.retry() })
                            .id(message.id)
                    }
                    // Anchor for keeping the newest token in view.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: model.session.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: model.session.messages.count) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let bottomAnchor = "peek.transcript.bottom"

    @ViewBuilder
    private var contextArea: some View {
        switch model.selection {
        case .captured(let context) where !model.contextDismissed:
            ContextChip(context: context,
                        fromScreen: model.recognizedFromScreen) { model.dismissContext() }
        case .permissionRequired:
            AccessibilityCard(
                onGrant: { model.requestAccessibilityPermission() },
                onOpenSettings: { model.openAccessibilitySettings() }
            )
        case .unsupported(let appName):
            ReadFromScreenCard(
                appName: appName,
                isWorking: model.isRecognizingText,
                error: model.recognitionError,
                onRead: { model.readFromScreen() }
            )
        case .empty(let appName) where model.canReadFromScreen:
            // The app exposed no selection API and the clipboard fallback also
            // came back with nothing — reading the screen is what is left.
            ReadFromScreenCard(
                appName: appName,
                isWorking: model.isRecognizingText,
                error: model.recognitionError,
                onRead: { model.readFromScreen() }
            )
        case .withheld(let appName):
            NoteRow(icon: "hand.raised",
                    text: "Peek doesn't read from \(appName ?? "this app").")
        case .empty(let appName):
            if model.session.isEmpty {
                NoteRow(icon: "text.cursor",
                        text: "Nothing selected in \(appName ?? "the previous app").")
            }
        case .captured:
            EmptyView()
        case .none:
            if model.session.isEmpty {
                NoteRow(icon: "ellipsis", text: "Reading selection\u{2026}")
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                AttachmentStrip(attachments: model.attachments) { model.removeAttachment($0) }
            }

            if let error = model.screenshotError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle").imageScale(.small)
                    Text(error).font(.system(size: 10))
                    if !ScreenRecordingPermission.isGranted {
                        Button("Open Settings") { ScreenRecordingPermission.openSettings() }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Capture Screen") { model.captureScreen() }
                    Button("Capture Region…") { model.captureRegion() }
                } label: {
                    Image(systemName: model.isCapturingScreenshot
                          ? "camera.fill" : "camera")
                        .imageScale(.medium)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .disabled(model.isCapturingScreenshot)
                .help("Attach a screenshot")
                .accessibilityLabel("Attach a screenshot")

                PromptEditor(text: $model.prompt,
                             minHeight: 20,
                             maxHeight: 110,
                             placeholder: placeholder,
                             font: .systemFont(ofSize: 13),
                             onSubmit: send,
                             measuredHeight: $composerHeight)
                    .frame(height: composerHeight)

                if model.canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .imageScale(.small)
                            .fontWeight(.semibold)
                    }
                    // Liquid Glass belongs on controls layered over content,
                    // not on the panel background: a full-bleed glass surface
                    // over arbitrary desktop loses legibility, which is why the
                    // panel chrome stays an NSVisualEffectView.
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(model.session.isStreaming)
                    .help("Send (\u{21A9})")
                }
            }

            HStack(spacing: 10) {
                if !model.hasCredentials {
                    Button("Add an API key to get started") { model.openSettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
                KeyHint(key: "return", label: "Send")
                KeyHint(key: "esc", label: "Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        model.activeContext == nil ? "Ask anything…" : "Ask about the selection…"
    }

    private func send() {
        model.send()
    }
}

// MARK: - Pieces

private struct ContextChip: View {
    let context: SelectionContext
    /// Text read from the screen is labelled as such: OCR can misread, and the
    /// user should know whether they are looking at the app's own text or
    /// Peek's reading of the pixels.
    var fromScreen: Bool = false
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: fromScreen ? "text.viewfinder" : "text.quote")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(context.sourceAppName ?? "Selection")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if fromScreen {
                    Text("read from screen")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if context.wasTruncated {
                    Text("truncated")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "xmark").imageScale(.small).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove this context")
                .accessibilityLabel("Remove selected text context")
            }

            Text(context.text)
                .font(.system(size: 12))
                .lineLimit(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Offered when an app exposes no selection at all.
///
/// Recognising text from the screen is the last resort in the capture cascade
/// and is deliberately a choice rather than an automatic fallback: Peek cannot
/// know which part of the screen the user meant, and reading all of it would
/// supply a wall of unrelated text as context.
private struct ReadFromScreenCard: View {
    let appName: String?
    let isWorking: Bool
    let error: String?
    let onRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "text.viewfinder").imageScale(.small)
                Text("\(appName ?? "This app") doesn't share selected text")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)

            Text("Peek can read it from the screen instead. Drag over the part you mean — recognition happens on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: onRead) {
                    if isWorking {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("Reading\u{2026}")
                        }
                    } else {
                        Text("Read from Screen")
                    }
                }
                .controlSize(.small)
                .disabled(isWorking)

                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AccessibilityCard: View {
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").imageScale(.small)
                Text("Reading your selection needs Accessibility")
                    .font(.system(size: 12, weight: .medium))
            }
            Text("Peek uses macOS Accessibility to read the text you had selected. "
                 + "Nothing is read until you invoke Peek, and never from password managers.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Grant Access…", action: onGrant).controlSize(.small)
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small).buttonStyle(.link)
            }
            Text("Then invoke Peek again.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NoteRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).imageScale(.small).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Attachments

private struct AttachmentStrip: View {
    let attachments: [PanelViewModel.PendingAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { pending in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let preview = pending.preview {
                                Image(nsImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 84, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        )

                        Button {
                            onRemove(pending.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .help("Remove this screenshot")
                        .accessibilityLabel("Remove screenshot")
                    }
                    .overlay(alignment: .bottomLeading) {
                        // Size is worth surfacing: it is what the request costs.
                        Text(ByteCountFormatter.string(fromByteCount: Int64(pending.byteCount),
                                                       countStyle: .file))
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 3)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 60)
    }
}
