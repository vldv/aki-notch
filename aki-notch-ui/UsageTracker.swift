//
//  UsageTracker.swift
//  aki-notch-ui
//
//  Tracks LLM token usage and cost per character, persisted to disk.
//  Provides aggregated statistics for the Usage tab in Settings.
//

import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "UsageTracker")

/// A single usage record from one LLM call.
struct UsageRecord: Codable, Sendable {
    let characterName: String
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let timestamp: Date
}

/// Aggregated usage statistics for display.
struct UsageStats {
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalTokens: Int
    let recordCount: Int
    let perCharacter: [String: CharacterUsageStats]
    let perDay: [String: DayUsageStats]  // key: "YYYY-MM-DD"
    let perModel: [String: ModelUsageStats]
    let totalEstimatedCost: Double
}

struct CharacterUsageStats {
    let characterName: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let callCount: Int
}

struct DayUsageStats {
    let date: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
}

struct ModelUsageStats {
    let model: String
    let provider: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let callCount: Int
    let estimatedCost: Double  // computed from pricing
}

/// Model pricing in dollars per million tokens.
/// Stored as a JSON file alongside usage data.
struct ModelPricing: Codable {
    var inputPerMillion: Double  // $/M input tokens
    var outputPerMillion: Double  // $/M output tokens
}

/// Singleton that tracks and persists LLM token usage.
@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    @Published private(set) var records: [UsageRecord] = []

    /// Model pricing map: model ID → pricing.
    /// Persisted to ~/.akiapp/model_pricing.json
    @Published var modelPricing: [String: ModelPricing] = [:]

    private let fileURL: URL
    private let pricingURL: URL

    private static let defaultPricing: [String: ModelPricing] = [
        "claude-sonnet-4-20250514": ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-haiku-35-20241022": ModelPricing(inputPerMillion: 0.80, outputPerMillion: 4.0),
        "claude-opus-4-6": ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0),
        "gpt-4o": ModelPricing(inputPerMillion: 2.5, outputPerMillion: 10.0),
        "gpt-4o-mini": ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60),
    ]

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let container = homeDir.appendingPathComponent(".akiapp", isDirectory: true)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        self.fileURL = container.appendingPathComponent("usage.json")
        self.pricingURL = container.appendingPathComponent("model_pricing.json")

        load()
        loadPricing()
    }

    /// Record a usage event from an LLM call.
    func record(characterName: String, provider: String, model: String, usage: LLMUsage) {
        guard usage.inputTokens > 0 || usage.outputTokens > 0 else { return }
        let record = UsageRecord(
            characterName: characterName,
            provider: provider,
            model: model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            timestamp: Date()
        )
        records.append(record)
        save()
    }

    /// Compute aggregated statistics.
    func computeStats() -> UsageStats {
        var totalIn = 0
        var totalOut = 0
        var byChar: [String: (input: Int, output: Int, count: Int)] = [:]
        var byDay: [String: (input: Int, output: Int)] = [:]
        var byModel: [String: (provider: String, input: Int, output: Int, count: Int)] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for r in records {
            totalIn += r.inputTokens
            totalOut += r.outputTokens

            var cs = byChar[r.characterName] ?? (input: 0, output: 0, count: 0)
            cs.input += r.inputTokens
            cs.output += r.outputTokens
            cs.count += 1
            byChar[r.characterName] = cs

            let day = dayFormatter.string(from: r.timestamp)
            var ds = byDay[day] ?? (input: 0, output: 0)
            ds.input += r.inputTokens
            ds.output += r.outputTokens
            byDay[day] = ds

            var ms = byModel[r.model] ?? (provider: r.provider, input: 0, output: 0, count: 0)
            ms.input += r.inputTokens
            ms.output += r.outputTokens
            ms.count += 1
            byModel[r.model] = ms
        }

        let charStats = byChar.map { (name, stats) in
            CharacterUsageStats(
                characterName: name,
                inputTokens: stats.input,
                outputTokens: stats.output,
                totalTokens: stats.input + stats.output,
                callCount: stats.count
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        let dayStats = byDay.map { (day, stats) in
            DayUsageStats(
                date: day,
                inputTokens: stats.input,
                outputTokens: stats.output,
                totalTokens: stats.input + stats.output
            )
        }.sorted { $0.date < $1.date }

        var modelStatsArray: [ModelUsageStats] = []
        for (model, stats) in byModel {
            let pricing: ModelPricing? = modelPricing[model]
            let inputCost: Double = Double(stats.input) / 1_000_000
            let outputCost: Double = Double(stats.output) / 1_000_000
            let cost: Double
            if let p = pricing {
                cost = inputCost * p.inputPerMillion + outputCost * p.outputPerMillion
            } else {
                cost = 0.0
            }
            let entry = ModelUsageStats(
                model: model,
                provider: stats.provider,
                inputTokens: stats.input,
                outputTokens: stats.output,
                totalTokens: stats.input + stats.output,
                callCount: stats.count,
                estimatedCost: cost
            )
            modelStatsArray.append(entry)
        }
        let modelStats: [ModelUsageStats] = modelStatsArray.sorted {
            $0.totalTokens > $1.totalTokens
        }

        let totalCost = modelStats.reduce(0.0) { $0 + $1.estimatedCost }

        return UsageStats(
            totalInputTokens: totalIn,
            totalOutputTokens: totalOut,
            totalTokens: totalIn + totalOut,
            recordCount: records.count,
            perCharacter: Dictionary(
                uniqueKeysWithValues: charStats.map { ($0.characterName, $0) }),
            perDay: Dictionary(uniqueKeysWithValues: dayStats.map { ($0.date, $0) }),
            perModel: Dictionary(uniqueKeysWithValues: modelStats.map { ($0.model, $0) }),
            totalEstimatedCost: totalCost
        )
    }

    /// Clear all usage data.
    func clearAll() {
        records = []
        save()
    }

    // MARK: - Pricing Management

    func setPricing(for model: String, input: Double, output: Double) {
        modelPricing[model] = ModelPricing(inputPerMillion: input, outputPerMillion: output)
        savePricing()
    }

    func removePricing(for model: String) {
        modelPricing.removeValue(forKey: model)
        savePricing()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([UsageRecord].self, from: data)
            logger.info("Loaded \(self.records.count) usage records")
        } catch {
            logger.error("Failed to load usage data: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save usage data: \(error.localizedDescription)")
        }
    }

    private func loadPricing() {
        guard FileManager.default.fileExists(atPath: pricingURL.path) else {
            // Seed with defaults on first launch
            modelPricing = Self.defaultPricing
            savePricing()
            logger.info("Seeded default model pricing for \(self.modelPricing.count) models")
            return
        }
        do {
            let data = try Data(contentsOf: pricingURL)
            modelPricing = try JSONDecoder().decode([String: ModelPricing].self, from: data)
            logger.info("Loaded pricing for \(self.modelPricing.count) models")
        } catch {
            logger.error("Failed to load model pricing: \(error.localizedDescription)")
            modelPricing = Self.defaultPricing
        }
    }

    private func savePricing() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(modelPricing)
            try data.write(to: pricingURL, options: .atomic)
        } catch {
            logger.error("Failed to save model pricing: \(error.localizedDescription)")
        }
    }
}
