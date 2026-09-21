import SwiftUI
import PeekCore
import PeekPersistence

/// Conversation history: search, open, rename, delete.
struct HistoryView: View {

    @Bindable var model: HistoryViewModel
    let onOpen: (ConversationID) -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var renamingID: ConversationID?
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            TextField("Search conversations", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            Button(action: onClose) {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close history")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.conversations.isEmpty {
            VStack(spacing: 4) {
                Spacer()
                Text(model.query.isEmpty ? "No conversations yet" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.conversations) { conversation in
                        row(for: conversation)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func row(for conversation: ConversationSummary) -> some View {
        if renamingID == conversation.id {
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                .onSubmit {
                    model.rename(conversation.id, to: renameText)
                    renamingID = nil
                }
                .onExitCommand { renamingID = nil }
        } else {
            Button {
                onOpen(conversation.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(conversation.updatedAt, format: .relative(presentation: .numeric))
                        if let app = conversation.sourceAppName {
                            Text("·")
                            Text(app)
                        }
                        Text("·")
                        Text("\(conversation.messageCount) message\(conversation.messageCount == 1 ? "" : "s")")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.001))
            .contextMenu {
                Button("Rename") {
                    renameText = conversation.title
                    renamingID = conversation.id
                }
                Button("Delete", role: .destructive) {
                    model.delete(conversation.id)
                }
            }
        }
    }
}
