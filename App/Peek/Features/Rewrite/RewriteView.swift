import SwiftUI
import PeekCore

/// The rewrite surface: what you wrote, what Peek proposes, and one decision.
struct RewriteView: View {

    @Bindable var model: RewriteViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    originalBlock
                    proposedBlock
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Divider().opacity(0.5)
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.sparkles")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(model.action.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if let app = model.sourceAppName {
                Text("in \(app)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if case .running = model.phase {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Text blocks

    private var originalBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Your text", systemImage: "text.alignleft")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(model.original)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var proposedBlock: some View {
        switch model.phase {
        case .failed(let message):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle").imageScale(.small)
                Text(message).font(.system(size: 12))
            }
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .replaced(let route):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").imageScale(.small)
                    Text(route == .accessibility
                         ? "Replaced in \(model.sourceAppName ?? "the app")."
                         : "Pasted into \(model.sourceAppName ?? "the app").")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.green)

                // Undo is not available through either write route, so the
                // recovery offered is one that always works.
                Text("Undo may not restore this. Your original text is safe here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        default:
            VStack(alignment: .leading, spacing: 4) {
                Label(model.isUnchanged ? "No changes needed" : "Peek's version",
                      systemImage: "sparkles")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                if model.proposed.isEmpty {
                    Text("Rewriting\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(model.proposed)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if case .replaced = model.phase {
                Button(model.didCopyOriginal ? "Original Copied" : "Copy Original") {
                    model.copyOriginal()
                }
                .controlSize(.small)
                .disabled(model.didCopyOriginal)

                Spacer()
                Button("Done", action: onDismiss)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            } else {
                Menu {
                    ForEach(RewriteAction.presets, id: \.self) { preset in
                        Button(preset.title) { model.change(to: preset) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").imageScale(.small)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Change what Peek does")

                Button("Copy") { model.copyProposed() }
                    .controlSize(.small)
                    .disabled(model.proposed.isEmpty)

                Spacer()

                Button("Replace") { model.replace() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canReplace)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
