import SwiftUI
import PeekCore

/// Panel contents.
struct PanelRootView: View {

    @Bindable var model: PanelViewModel
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            contextArea
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
            if model.isCapturing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var contextArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
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
                case .empty, .captured, .none:
                    NoteRow(icon: "text.cursor",
                            text: "Select text in another app to add context.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            TextField("Ask anything…", text: $model.prompt, axis: .vertical)
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
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove this context")
                .accessibilityLabel("Remove selected text context")
            }

            Text(context.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(6)
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
                Image(systemName: "lock.shield")
                    .imageScale(.small)
                Text("Reading your selection needs Accessibility")
                    .font(.system(size: 12, weight: .medium))
            }

            Text("Peek uses macOS Accessibility to read the text you had selected. "
                 + "Nothing is read until you invoke Peek, and never from password managers.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Grant Access…", action: onGrant)
                    .controlSize(.small)
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small)
                    .buttonStyle(.link)
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
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
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
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    PanelRootView(model: PanelViewModel())
        .frame(width: 440, height: 300)
}
