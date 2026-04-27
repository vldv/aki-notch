//
//  UsageView.swift
//  aki-notch-ui
//
//  Token usage statistics tab in Settings. Shows per-character, per-model,
//  and per-day usage with simple bar chart visualization and cost estimates.
//

import SwiftUI

struct UsageView: View {
    @ObservedObject var usageTracker = UsageTracker.shared

    /// Build a 30-day array of daily stats, filling missing days with zeros.
    private func buildLast30Days(from stats: UsageStats) -> [DayUsageStats] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayLookup = Dictionary(uniqueKeysWithValues: stats.perDay.values.map { ($0.date, $0) })

        return (0..<30).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = dayFormatter.string(from: date)
            return dayLookup[key]
                ?? DayUsageStats(date: key, inputTokens: 0, outputTokens: 0, totalTokens: 0)
        }
    }

    var body: some View {
        let stats = usageTracker.computeStats()

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Total since last reset ──
                if let oldest = usageTracker.records.first?.timestamp {
                    HStack {
                        Text("Total since last reset:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(oldest, style: .date)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                // ── Summary cards ──
                HStack(spacing: 16) {
                    StatCard(
                        title: "Total Tokens",
                        value: formatNumber(stats.totalTokens),
                        subtitle: "\(stats.recordCount) API calls",
                        color: .cyan
                    )
                    StatCard(
                        title: "Input",
                        value: formatNumber(stats.totalInputTokens),
                        subtitle: "prompt tokens",
                        color: .blue
                    )
                    StatCard(
                        title: "Output",
                        value: formatNumber(stats.totalOutputTokens),
                        subtitle: "completion tokens",
                        color: .green
                    )
                    StatCard(
                        title: "Est. Cost",
                        value: String(format: "$%.2f", stats.totalEstimatedCost),
                        subtitle: "based on model pricing",
                        color: .orange
                    )
                }
                .padding(.horizontal)

                // ── Per-character breakdown ──
                if !stats.perCharacter.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("BY CHARACTER")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        let sorted = stats.perCharacter.values.sorted {
                            $0.totalTokens > $1.totalTokens
                        }
                        let maxTokens = sorted.first?.totalTokens ?? 1

                        ForEach(sorted, id: \.characterName) { charStat in
                            HStack(spacing: 12) {
                                Text(charStat.characterName)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 80, alignment: .leading)
                                    .lineLimit(1)

                                // Bar chart
                                GeometryReader { geo in
                                    let totalWidth = geo.size.width
                                    let inputWidth =
                                        totalWidth * CGFloat(charStat.inputTokens)
                                        / CGFloat(max(1, maxTokens))
                                    let outputWidth =
                                        totalWidth * CGFloat(charStat.outputTokens)
                                        / CGFloat(max(1, maxTokens))

                                    HStack(spacing: 1) {
                                        Rectangle()
                                            .fill(Color.blue.opacity(0.7))
                                            .frame(width: max(2, inputWidth))
                                        Rectangle()
                                            .fill(Color.green.opacity(0.7))
                                            .frame(width: max(2, outputWidth))
                                        Spacer(minLength: 0)
                                    }
                                }
                                .frame(height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 3))

                                Text(formatNumber(charStat.totalTokens))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                // ── Per-model breakdown ──
                if !stats.perModel.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("BY MODEL")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        let sorted = stats.perModel.values.sorted {
                            $0.totalTokens > $1.totalTokens
                        }
                        let maxTokens = sorted.first?.totalTokens ?? 1

                        ForEach(sorted, id: \.model) { modelStat in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(modelStat.model)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Text(modelStat.provider)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .frame(width: 180, alignment: .leading)

                                    GeometryReader { geo in
                                        let totalWidth = geo.size.width
                                        let inputW =
                                            totalWidth * CGFloat(modelStat.inputTokens)
                                            / CGFloat(max(1, maxTokens))
                                        let outputW =
                                            totalWidth * CGFloat(modelStat.outputTokens)
                                            / CGFloat(max(1, maxTokens))
                                        HStack(spacing: 1) {
                                            Rectangle().fill(Color.blue.opacity(0.7)).frame(
                                                width: max(2, inputW))
                                            Rectangle().fill(Color.green.opacity(0.7)).frame(
                                                width: max(2, outputW))
                                            Spacer(minLength: 0)
                                        }
                                    }
                                    .frame(height: 14)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))

                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(formatNumber(modelStat.totalTokens))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        if modelStat.estimatedCost > 0 {
                                            Text(String(format: "$%.3f", modelStat.estimatedCost))
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .frame(width: 60, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                // ── Daily usage chart (last 30 days) ──
                dailyUsageChart(stats: stats)
                    .padding(.horizontal)

                // ── Model Pricing ──
                if !stats.perModel.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MODEL PRICING")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)

                        Text(
                            "Set pricing per million tokens to estimate costs. Leave at 0 for unknown models."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        let models = stats.perModel.values.sorted { $0.model < $1.model }

                        ForEach(models, id: \.model) { modelStat in
                            HStack(spacing: 8) {
                                Text(modelStat.model)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)

                                Text("In:")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "$/M",
                                    value: Binding(
                                        get: {
                                            usageTracker.modelPricing[modelStat.model]?
                                                .inputPerMillion ?? 0
                                        },
                                        set: { newValue in
                                            let outputPrice =
                                                usageTracker.modelPricing[modelStat.model]?
                                                .outputPerMillion ?? 0
                                            usageTracker.setPricing(
                                                for: modelStat.model, input: newValue,
                                                output: outputPrice)
                                        }
                                    ), format: .number.precision(.fractionLength(2))
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .font(.system(size: 10, design: .monospaced))

                                Text("Out:")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "$/M",
                                    value: Binding(
                                        get: {
                                            usageTracker.modelPricing[modelStat.model]?
                                                .outputPerMillion ?? 0
                                        },
                                        set: { newValue in
                                            let inputPrice =
                                                usageTracker.modelPricing[modelStat.model]?
                                                .inputPerMillion ?? 0
                                            usageTracker.setPricing(
                                                for: modelStat.model, input: inputPrice,
                                                output: newValue)
                                        }
                                    ), format: .number.precision(.fractionLength(2))
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .font(.system(size: 10, design: .monospaced))
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                // ── Legend ──
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.blue.opacity(0.7)).frame(width: 8, height: 8)
                        Text("Input").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.green.opacity(0.7)).frame(width: 8, height: 8)
                        Text("Output").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()

                    // Clear button
                    Button {
                        usageTracker.clearAll()
                    } label: {
                        Text("Clear Usage Data")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)

                // ── Empty state ──
                if stats.recordCount == 0 {
                    VStack(spacing: 8) {
                        Text("No usage data yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Token usage will appear here as you interact with characters.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }

                Spacer()
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    // MARK: - Daily Usage Chart

    @ViewBuilder
    private func dailyUsageChart(stats: UsageStats) -> some View {
        let last30 = buildLast30Days(from: stats)
        let maxDay = max(1, last30.map(\.totalTokens).max() ?? 1)
        let barHeight: CGFloat = 140

        VStack(alignment: .leading, spacing: 12) {
            Text("DAILY USAGE (LAST 30 DAYS)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(last30.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        if day.totalTokens > 0 {
                            Rectangle()
                                .fill(Color.green.opacity(0.7))
                                .frame(
                                    height: max(
                                        1,
                                        CGFloat(day.outputTokens) / CGFloat(maxDay) * barHeight)
                                )
                            Rectangle()
                                .fill(Color.blue.opacity(0.7))
                                .frame(
                                    height: max(
                                        1,
                                        CGFloat(day.inputTokens) / CGFloat(maxDay) * barHeight)
                                )
                        } else {
                            Rectangle()
                                .fill(Color.white.opacity(0.05))
                                .frame(height: 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .help(dayTooltip(day))
                }
            }
            .frame(height: barHeight)

            HStack(spacing: 2) {
                ForEach(Array(last30.enumerated()), id: \.offset) { index, day in
                    Text(index % 5 == 0 ? dayLabel(day.date) : "")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func dayLabel(_ dateString: String) -> String {
        // "2026-04-27" → "27"
        return String(dateString.suffix(2))
    }

    private func dayTooltip(_ day: DayUsageStats) -> String {
        let date = String(day.date.suffix(5))  // "04-27"
        if day.totalTokens == 0 { return "\(date): no usage" }
        return
            "\(date): \(formatNumber(day.totalTokens)) tokens (\(formatNumber(day.inputTokens)) in / \(formatNumber(day.outputTokens)) out)"
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
