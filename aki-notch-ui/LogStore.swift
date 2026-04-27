//
//  LogStore.swift
//  aki-notch-ui
//
//  Centralized in-app log buffer that drives the Live Logs settings tab.
//
//  Components call `LogStore.shared.append(...)` to record events.
//  The store keeps a capped ring of recent entries and publishes
//  changes so SwiftUI views update in real time.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Log Entry

/// A single log entry with timestamp, severity, category, and message.
struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: Level
    let category: String
    let message: String

    enum Level: String, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        var color: Color {
            switch self {
            case .debug: return .secondary
            case .info: return .primary
            case .warning: return .yellow
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    /// Compact timestamp for display: "HH:mm:ss"
    var timestamp: String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Log Store

/// Observable, capped buffer of log entries.
///
/// Usage from anywhere:
/// ```
/// LogStore.shared.info("AgentBrain", "Starting think cycle for Aki")
/// LogStore.shared.warning("TriggerEngine", "Suppressed — mic in use")
/// ```
@MainActor
final class LogStore: ObservableObject {

    static let shared = LogStore()

    /// Maximum number of entries kept in the buffer.
    static let maxEntries = 500

    @Published private(set) var entries: [LogEntry] = []

    /// The set of categories that have appeared so far (for filtering).
    @Published private(set) var categories: Set<String> = []

    private init() {}

    // MARK: - Append

    func append(_ level: LogEntry.Level, _ category: String, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)
        entries.append(entry)
        categories.insert(category)

        // Trim from the front if we exceed the cap.
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    // MARK: - Convenience

    func debug(_ category: String, _ message: String) {
        append(.debug, category, message)
    }

    func info(_ category: String, _ message: String) {
        append(.info, category, message)
    }

    func warning(_ category: String, _ message: String) {
        append(.warning, category, message)
    }

    func error(_ category: String, _ message: String) {
        append(.error, category, message)
    }

    // MARK: - Clear

    func clear() {
        entries.removeAll()
    }
}
