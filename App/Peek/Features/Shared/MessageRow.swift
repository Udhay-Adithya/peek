import SwiftUI
import PeekCore

/// One turn in a transcript. Shared by the floating panel and the
/// expanded window so both render conversations identically.
struct MessageRow: View {
    let message: AssistantSession.DisplayMessage
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.role == .user {
                if let context = message.contextText, !context.isEmpty {
                    // The subject of the question, shown as a quote so it reads
                    // as context rather than as something the user typed.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.quote").imageScale(.small)
                            Text(message.contextSourceApp ?? "Selection")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.tertiary)

                        Text(context)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(.tertiary)
                            .frame(width: 2)
                            .clipShape(RoundedRectangle(cornerRadius: 1))
                    }
                }

                if message.attachmentCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "photo").imageScale(.small)
                        Text("\(message.attachmentCount) screenshot\(message.attachmentCount == 1 ? "" : "s")")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.render(message.text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let usage = message.usage, !message.isStreaming {
                    Text("\(usage.inputTokens) in · \(usage.outputTokens) out")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
        }
    }

    private static func render(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

