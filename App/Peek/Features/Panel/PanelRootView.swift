import SwiftUI
import PeekCore

/// Panel contents: context, transcript and composer.
struct PanelRootView: View {

    @Bindable var model: PanelViewModel
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            transcript
            Divider().opacity(0.5)
            composer
        }
        .onAppear { promptFocused = true }
        .sheet(isPresented: $model.isShowingHistory) {
            HistoryView(
                model: model.history,
                onOpen: { model.openConversation($0) },
                onClose: { model.isShowingHistory = false }
            )
            .frame(width: 420, height: 340)
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
            ContextChip(context: context) { model.dismissContext() }
        case .permissionRequired:
            AccessibilityCard(
                onGrant: { model.requestAccessibilityPermission() },
                onOpenSettings: { model.openAccessibilitySettings() }
            )
        case .unsupported(let appName):
            NoteRow(icon: "info.circle",
                    text: "\(appName ?? "This app") doesn't share selected text.")
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
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($promptFocused)
                    .onSubmit(send)

                if model.canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(model.session.isStreaming)
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
        promptFocused = true
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: AssistantSession.DisplayMessage
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.role == .user {
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                assistantBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var assistantBody: some View {
        if let failure = message.failure {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                    Text(failure).font(.system(size: 12))
                }
                .foregroundStyle(.orange)

                if message.isRetryable {
                    Button("Retry", action: onRetry)
                        .controlSize(.small)
                }
            }
        } else if message.text.isEmpty, message.isStreaming {
            // Thinking indicator before the first token lands.
            ProgressView().controlSize(.small).scaleEffect(0.7)
        } else {
            // Markdown via AttributedString: native, no third-party renderer.
            // Falls back to plain text mid-stream, when the markup is
            // necessarily incomplete.
            Text(Self.render(message.text))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func render(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

// MARK: - Pieces

private struct ContextChip: View {
    let context: SelectionContext
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "text.quote")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(context.sourceAppName ?? "Selection")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
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

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
