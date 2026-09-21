import SwiftUI

/// Panel contents.
///
/// Placeholder chrome for now — the conversation view arrives with the
/// streaming phase. What is real here is the layout, focus behaviour and
/// keyboard affordances, which the rest of the UI will be built inside.
struct PanelRootView: View {

    @State private var prompt: String = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            conversationPlaceholder
            Divider().opacity(0.5)
            composer
        }
        .onAppear { promptFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text("Peek")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var conversationPlaceholder: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Ask about anything on screen")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Selected text will appear here as context")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            TextField("Ask anything…", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($promptFocused)

            HStack(spacing: 10) {
                Spacer()
                KeyHint(key: "return", label: "Send")
                KeyHint(key: "esc", label: "Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    PanelRootView()
        .frame(width: 440, height: 300)
}
