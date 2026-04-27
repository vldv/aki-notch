// HistoryStore.swift — aki-notch-ui
//
//  Persistent conversation history store that records character messages,
//  user messages, and system events to a JSON file on disk.
//
//  Components call `HistoryStore.shared.recordCharacterMessage(...)` etc.
//  The store keeps a capped buffer of recent entries, publishes changes
//  for SwiftUI views, and debounce-saves to disk every 2 seconds.
//

import Combine
import Foundation
import os

// MARK: - History Entry

/// A single conversation history entry with sender, color, and message.
struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let senderName: String
    let accentColorHex: String
    let message: String
    let type: EntryType
    /// The mood/face name used for this message (e.g. "happy", "angry").
    /// Only present for character messages where the face was known at recording time.
    let faceName: String?

    enum EntryType: String, Codable, CaseIterable {
        case characterMessage
        case userMessage
        case system
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        senderName: String,
        accentColorHex: String,
        message: String,
        type: EntryType,
        faceName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.senderName = senderName
        self.accentColorHex = accentColorHex
        self.message = message
        self.type = type
        self.faceName = faceName
    }

    // MARK: Backward-compatible decoding

    /// Custom decoder so that history files written before the `faceName` field
    /// was added can still be loaded without error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        senderName = try container.decode(String.self, forKey: .senderName)
        accentColorHex = try container.decode(String.self, forKey: .accentColorHex)
        message = try container.decode(String.self, forKey: .message)
        type = try container.decode(EntryType.self, forKey: .type)
        faceName = try container.decodeIfPresent(String.self, forKey: .faceName)
    }

    /// Compact timestamp for display: "HH:mm".
    var timestamp: String {
        Self.timeFormatter.string(from: date)
    }

    /// Day stamp for section headers: "MMM d, yyyy".
    var dayStamp: String {
        Self.dayFormatter.string(from: date)
    }

    // MARK: Formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}

// MARK: - History Store

/// Observable, capped, persistent buffer of conversation history entries.
///
/// Usage from anywhere:
/// ```
/// HistoryStore.shared.recordCharacterMessage(
///     characterName: "Aki",
///     accentColorHex: "#7FD6FF",
///     message: "Hello there!"
/// )
/// HistoryStore.shared.recordUserMessage(message: "Hi Aki!")
/// HistoryStore.shared.recordSystemMessage(message: "Session started")
/// ```
@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    /// Maximum number of entries kept in the buffer.
    static let maxEntries = 2000

    @Published private(set) var entries: [HistoryEntry] = []

    private let logger = Logger(subsystem: "com.aki-notch-ui", category: "HistoryStore")

    /// File URL for the persisted history JSON.
    private let fileURL: URL

    /// Pending save work item for debouncing disk writes.
    private var pendingSave: DispatchWorkItem?

    /// Debounce interval for saving to disk (seconds).
    private let saveDebounceInterval: TimeInterval = 2.0

    // MARK: JSON Coding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    private init() {
        AkiAppMigration.runIfNeeded()

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let container = homeDir.appendingPathComponent(".akiapp", isDirectory: true)
        self.fileURL = container.appendingPathComponent("history.json")

        ensureDirectory(container)
        loadFromDisk()
    }

    // MARK: - Append

    /// Append a new history entry with the given properties.
    func append(
        senderName: String,
        accentColorHex: String,
        message: String,
        type: HistoryEntry.EntryType,
        faceName: String? = nil
    ) {
        let entry = HistoryEntry(
            senderName: senderName,
            accentColorHex: accentColorHex,
            message: message,
            type: type,
            faceName: faceName
        )
        entries.append(entry)

        // Trim oldest entries if we exceed the cap.
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }

        scheduleSave()
    }

    // MARK: - Convenience

    /// Record a message from a character.
    func recordCharacterMessage(
        characterName: String,
        accentColorHex: String,
        message: String,
        faceName: String? = nil
    ) {
        append(
            senderName: characterName,
            accentColorHex: accentColorHex,
            message: message,
            type: .characterMessage,
            faceName: faceName
        )
    }

    /// Record a message from the user.
    func recordUserMessage(message: String) {
        append(
            senderName: "You",
            accentColorHex: "#FFFFFF",
            message: message,
            type: .userMessage
        )
    }

    /// Record a system event.
    func recordSystemMessage(message: String) {
        append(
            senderName: "System",
            accentColorHex: "#888888",
            message: message,
            type: .system
        )
    }

    // MARK: - Queries

    /// Filter entries belonging to a specific character name.
    func entries(forCharacter name: String) -> [HistoryEntry] {
        entries.filter { $0.senderName == name }
    }

    /// Unique character names (excluding "You" and "System"), sorted alphabetically.
    var characterNames: [String] {
        Array(
            Set(
                entries
                    .filter { $0.type == .characterMessage }
                    .map(\.senderName)
            )
        ).sorted()
    }

    // MARK: - Clear

    /// Remove all entries and delete the persisted file.
    func clear() {
        entries.removeAll()
        pendingSave?.cancel()
        pendingSave = nil

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            logger.error("Failed to delete history file: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    /// Ensure the container directory exists.
    private func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create history directory: \(error.localizedDescription)")
            }
        }
    }

    /// Load entries from the JSON file on disk.
    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try Self.decoder.decode([HistoryEntry].self, from: data)

            // Apply the cap in case the file was hand-edited or from an older version.
            if decoded.count > Self.maxEntries {
                entries = Array(decoded.suffix(Self.maxEntries))
            } else {
                entries = decoded
            }

            logger.info("Loaded \(self.entries.count) history entries from disk.")
        } catch {
            logger.error("Failed to load history from disk: \(error.localizedDescription)")
        }
    }

    /// Write current entries to the JSON file on disk.
    private func saveToDisk() {
        do {
            let data = try Self.encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save history to disk: \(error.localizedDescription)")
        }
    }

    /// Schedule a debounced save. Cancels any previously pending save and
    /// waits `saveDebounceInterval` seconds before actually writing to disk.
    private func scheduleSave() {
        pendingSave?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.saveToDisk()
            }
        }
        pendingSave = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + saveDebounceInterval,
            execute: workItem
        )
    }
}
