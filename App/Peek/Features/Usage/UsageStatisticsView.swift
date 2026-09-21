import Charts
import SwiftUI
import PeekCore

/// Token usage over time.
///
/// Form follows the data's job: totals are single headline numbers, so they are
/// stat tiles rather than charts; usage over time is change-over-time, so it is
/// a bar timeline; the per-model split is identity plus magnitude, so it is a
/// ranked horizontal bar with direct labels and no legend.
struct UsageStatisticsView: View {

    @Bindable var model: UsageStatisticsViewModel

    /// Two series, so a legend is mandatory — identity is never colour alone.
    private enum Series: String {
        case input = "Input"
        case output = "Output"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Filters sit in one row above the charts.
            HStack {
                Picker("Range", selection: $model.range) {
                    ForEach(UsageStatisticsViewModel.Range.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)

                Spacer()

                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if model.statistics.isEmpty {
                ContentUnavailableView("No Usage Yet",
                                       systemImage: "chart.bar",
                                       description: Text("Token counts appear here once a provider reports them. The on-device model reports none."))
                    .frame(height: 180)
            } else {
                summaryTiles
                dailyChart
                modelBreakdown
            }
        }
    }

    // MARK: - Totals

    private var summaryTiles: some View {
        HStack(spacing: 10) {
            StatTile(label: "Total tokens", value: model.statistics.totalTokens.formatted())
            StatTile(label: "Input", value: model.statistics.totalInputTokens.formatted(),
                     accent: .usageInput)
            StatTile(label: "Output", value: model.statistics.totalOutputTokens.formatted(),
                     accent: .usageOutput)
            StatTile(label: "Replies", value: model.statistics.assistantTurns.formatted())
            StatTile(label: "Conversations", value: model.statistics.conversationCount.formatted())
        }
    }

    // MARK: - Timeline

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tokens per day")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(model.statistics.days) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Tokens", day.inputTokens),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Series", Series.input.rawValue))
                    // 2px surface gap between stacked segments.
                    .cornerRadius(2)

                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Tokens", day.outputTokens),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Series", Series.output.rawValue))
                    .cornerRadius(2)
                }
            }
            .chartForegroundStyleScale([
                Series.input.rawValue: Color.usageInput,
                Series.output.rawValue: Color.usageOutput,
            ])
            .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    // Recessive grid; the data is the figure.
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text(count.abbreviatedTokens)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: model.range == .week ? 1 : 7)) { value in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 180)
        }
    }

    // MARK: - Per model

    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By model")
                .font(.caption)
                .foregroundStyle(.secondary)

            // One series, so no legend; values are labelled directly.
            Chart(model.statistics.models) { entry in
                BarMark(
                    x: .value("Tokens", entry.totalTokens),
                    y: .value("Model", entry.modelID)
                )
                .foregroundStyle(Color.usageInput)
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(entry.totalTokens.abbreviatedTokens)
                        .font(.caption2)
                        // Text keeps text tokens; the bar carries identity.
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: CGFloat(model.statistics.models.count) * 30 + 20)

            // A table view of the same data, so identity never depends on the
            // chart being legible.
            VStack(spacing: 2) {
                ForEach(model.statistics.models) { entry in
                    HStack {
                        Text(entry.modelID)
                            .font(.caption)
                        Spacer()
                        Text("\(entry.turns) replies")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("\(entry.inputTokens.formatted()) in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(entry.outputTokens.formatted()) out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Pieces

private struct StatTile: View {
    let label: String
    let value: String
    var accent: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let accent {
                    Circle().fill(accent).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Color {
    /// Categorical slots 1 and 2 of the validated reference palette.
    ///
    /// Blue/orange, chosen because the pair clears every colour-vision gate in
    /// both appearances with a wide margin (worst CVD ΔE 24.7 light / 26.8
    /// dark against an ≥8 target), rather than because they look pleasant.
    /// Each mode has its own step; dark is not an automatic flip of light.
    static let usageInput = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255, alpha: 1)
    })

    static let usageOutput = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xd9 / 255, green: 0x59 / 255, blue: 0x26 / 255, alpha: 1)
            : NSColor(srgbRed: 0xeb / 255, green: 0x68 / 255, blue: 0x34 / 255, alpha: 1)
    })
}

private extension Int {
    /// Compact axis and label form: 12.4k rather than 12,400.
    var abbreviatedTokens: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fk", Double(self) / 1_000)
        }
        return formatted()
    }
}
