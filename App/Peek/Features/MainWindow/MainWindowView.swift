import AppKit
import SwiftUI
import PeekCore
import PeekPersistence

/// The expanded, conventional window: conversation list beside a transcript.
///
/// Shares the same ``AssistantSession`` as the floating panel, so expanding
/// mid-conversation continues it rather than starting something new.
struct MainWindowView: View {

    @Bindable var session: AssistantSession
    @Bindable var history: HistoryViewModel
    @Bindable var router: MainWindowRouter
    @Bindable var settings: AppSettings
    @Bindable var usage: UsageStatisticsViewModel
    let updates: UpdateController
    let engine: AssistantEngine

    @State private var prompt: String = ""
    @State private var composerHeight: CGFloat = 22
    @FocusState private var promptFocused: Bool
    @State private var renamingID: ConversationID?
    @State private var renameText: String = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            switch router.pane {
            case .conversations: detail
            case .settings:      settingsPane
            }
        }
        .onAppear {
            history.refresh()
            promptFocused = true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { router.pane == .conversations ? session.conversationID : nil },
                set: { id in
                    if let id {
                        router.pane = .conversations
                        Task { await session.load(id) }
                    }
                }
            )) {
                ForEach(history.conversations) { conversation in
                    row(for: conversation)
                        .tag(conversation.id)
                }
            }
            .overlay {
                if history.conversations.isEmpty {
                    ContentUnavailableView(
                        history.query.isEmpty ? "No Conversations" : "No Matches",
                        systemImage: history.query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                        description: Text(history.query.isEmpty
                                          ? "Invoke Peek with ⌃⌥Space to start one."
                                          : "Try a different search.")
                    )
                }
            }

            Divider()

            Button {
                router.pane = .settings
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(router.pane == .settings ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            .keyboardShortcut(",", modifiers: .command)
        }
        .searchable(text: $history.query, prompt: "Search conversations")
        .toolbar {
            ToolbarItem {
                Button {
                    router.pane = .conversations
                    session.reset()
                    history.refresh()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New conversation (⌘N)")
            }
        }
    }

    @ViewBuilder
    private func row(for conversation: ConversationSummary) -> some View {
        if renamingID == conversation.id {
            TextField("Title", text: $renameText)
                .onSubmit {
                    history.rename(conversation.id, to: renameText)
                    renamingID = nil
                }
                .onExitCommand { renamingID = nil }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(conversation.updatedAt, format: .relative(presentation: .numeric))
                    if let app = conversation.sourceAppName {
                        Text("· \(app)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Rename") {
                    renameText = conversation.title
                    renamingID = conversation.id
                }
                Button("Delete", role: .destructive) {
                    history.delete(conversation.id)
                    if session.conversationID == conversation.id { session.reset() }
                }
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Model", selection: Binding(
                    get: { engine.selectedModelID },
                    set: { engine.selectModel($0) }
                )) {
                    ForEach(engine.currentProvider().models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
            }
        }
    }

    /// Settings rendered inside the window, rather than in a window of its own.
    private var settingsPane: some View {
        ScrollView {
            SettingsView(settings: settings, engine: engine, usage: usage, updates: updates)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.messages) { message in
                        MessageRow(message: message, onRetry: { session.retry() })
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .overlay {
                if session.isEmpty {
                    ContentUnavailableView("Ask Anything",
                                           systemImage: "text.magnifyingglass",
                                           description: Text("Or select text anywhere and press ⌃⌥Space."))
                }
            }
        }
    }

    private static let bottomAnchor = "peek.window.transcript.bottom"

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PromptEditor(text: $prompt,
                         minHeight: 22,
                         maxHeight: 180,
                         placeholder: "Ask anything…",
                         font: .systemFont(ofSize: NSFont.systemFontSize),
                         onSubmit: send,
                         measuredHeight: $composerHeight)
                .frame(height: composerHeight)

            if session.isStreaming {
                Button("Stop") { session.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        let outgoing = prompt
        guard !outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prompt = ""
        session.send(prompt: outgoing, context: nil)
        // The sidebar shows titles and timestamps that this turn changes.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            history.refresh()
        }
    }
}
