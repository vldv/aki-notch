// CharacterSession.swift — aki-notch-ui
//
//  Per-character persistent conversation session store.
//
//  Each character gets a JSON file under
//  ~/.akiapp/sessions/{Name}.json
//  that holds a flat list of SessionMessage entries. These are loaded at the
//  start of each think() cycle and saved at the end, giving characters memory
//  of past interactions across runs.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "CharacterSession")

// MARK: - SessionContentBlock

/// A single content block within a persisted session message.
struct SessionContentBlock: Codable, Sendable {
    /// Block type: "text", "toolUse", "toolResult", "imagePlaceholder"
    let type: String
    /// Text content (for text blocks), tool arguments JSON string (for toolUse),
    /// result text (for toolResult), or placeholder description (for imagePlaceholder).
    let text: String?
    /// Tool name (for toolUse blocks).
    let toolName: String?
    /// Tool call ID (for toolUse and toolResult blocks).
    let toolCallId: String?
}

// MARK: - SessionMessage

/// A simplified, serializable representation of an LLM message for session persistence.
/// Strips images (replaced with placeholders) and truncates long tool outputs to keep
/// sessions lean.
struct SessionMessage: Codable, Sendable {
    let role: String  // "user", "assistant", "toolResult"
    let content: [SessionContentBlock]
    let timestamp: Date

    /// Rough token estimate for this message (~4 chars per token).
    var estimatedTokens: Int {
        let charCount = content.reduce(0) { total, block in
            total + (block.text?.count ?? 0) + (block.toolName?.count ?? 0)
        }
        return max(1, charCount / 4)
    }
}

// MARK: - CharacterSession

/// Manages persistent conversation history for a single character.
///
/// Sessions are stored as JSON files in `~/.akiapp/sessions/`.
/// They hold a flat list of ``SessionMessage`` entries that are loaded into the
/// LLM context at the start of each `think()` cycle, giving characters memory
/// of past interactions.
@MainActor
final class CharacterSession {

    // MARK: Tuning constants

    /// Maximum character length for tool result text in session storage.
    static let maxToolResultLength = 500

    // MARK: Properties

    /// The character's name (used for file naming).
    let characterName: String

    /// The stored session messages.
    private(set) var messages: [SessionMessage] = []

    /// File URL for this character's session.
    private let fileURL: URL

    // MARK: Static cache

    /// Session cache — avoids re-creating sessions for the same character.
    private static var cache: [String: CharacterSession] = [:]

    /// Get or create a session for a character.
    static func session(for characterName: String) -> CharacterSession {
        if let existing = cache[characterName] {
            return existing
        }
        let session = CharacterSession(characterName: characterName)
        cache[characterName] = session
        return session
    }

    // MARK: - Init

    init(characterName: String) {
        self.characterName = characterName

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let sessionsDir =
            homeDir
            .appendingPathComponent(".akiapp", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: sessionsDir,
            withIntermediateDirectories: true
        )

        // Sanitize character name for filename
        let safeName =
            characterName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        self.fileURL = sessionsDir.appendingPathComponent("\(safeName).json")

    }

    // MARK: - Load / Save

    /// Load session from disk. Called at the start of think().
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            messages = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            messages = try decoder.decode([SessionMessage].self, from: data)
            logger.info(
                "Loaded \(self.messages.count) session message(s) for \(self.characterName)")
        } catch {
            logger.error(
                "Failed to load session for \(self.characterName): \(error.localizedDescription)")
            messages = []
        }
    }

    /// Save session to disk. Called at the end of think().
    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(self.messages.count) session message(s) for \(self.characterName)")
        } catch {
            logger.error(
                "Failed to save session for \(self.characterName): \(error.localizedDescription)")
        }
    }

    // MARK: - LLMMessage Conversion

    /// Convert stored session messages to ``LLMMessage`` array for injection into LLM context.
    func toLLMMessages() -> [LLMMessage] {
        messages.compactMap { msg -> LLMMessage? in
            guard let role = LLMMessage.Role(rawValue: msg.role) else {
                logger.warning("Unknown role '\(msg.role)' in session for \(self.characterName)")
                return nil
            }

            let contentBlocks: [LLMContent] = msg.content.compactMap { block in
                switch block.type {
                case "text":
                    return .text(block.text ?? "")

                case "toolUse":
                    let args = decodeArguments(block.text)
                    return .toolUse(
                        id: block.toolCallId ?? UUID().uuidString,
                        name: block.toolName ?? "",
                        arguments: args
                    )

                case "toolResult":
                    return .toolResult(
                        toolCallId: block.toolCallId ?? "",
                        content: block.text ?? "",
                        isError: false
                    )

                case "imagePlaceholder":
                    return .text("[user sent an image]")

                default:
                    logger.warning(
                        "Unknown block type '\(block.type)' in session for \(self.characterName)")
                    return nil
                }
            }

            guard !contentBlocks.isEmpty else { return nil }
            return LLMMessage(role: role, content: contentBlocks)
        }
    }

    /// Append new messages from an AgentLoop run to the session.
    /// Strips images, truncates long tool results, and adds timestamps.
    func appendMessages(_ llmMessages: [LLMMessage]) {
        let now = Date()
        for msg in llmMessages {
            let blocks: [SessionContentBlock] = msg.content.compactMap { content in
                switch content {
                case .text(let text):
                    return SessionContentBlock(
                        type: "text",
                        text: text,
                        toolName: nil,
                        toolCallId: nil
                    )

                case .image:
                    return SessionContentBlock(
                        type: "imagePlaceholder",
                        text: "[user sent an image]",
                        toolName: nil,
                        toolCallId: nil
                    )

                case .toolUse(let id, let name, let arguments):
                    let argsJSON = encodeArguments(arguments)
                    return SessionContentBlock(
                        type: "toolUse",
                        text: argsJSON,
                        toolName: name,
                        toolCallId: id
                    )

                case .toolResult(let toolCallId, let resultContent, _):
                    let truncated: String
                    if resultContent.count > Self.maxToolResultLength {
                        truncated = String(resultContent.prefix(Self.maxToolResultLength)) + "..."
                    } else {
                        truncated = resultContent
                    }
                    return SessionContentBlock(
                        type: "toolResult",
                        text: truncated,
                        toolName: nil,
                        toolCallId: toolCallId
                    )
                }
            }

            guard !blocks.isEmpty else { continue }

            messages.append(
                SessionMessage(
                    role: msg.role.rawValue,
                    content: blocks,
                    timestamp: now
                ))
        }
    }

    // MARK: - Compaction

    /// Check if compaction is needed and perform it if so.
    /// Uses the provided LLM client to summarize old messages into a single
    /// summary entry, keeping the most recent messages intact.
    func compactIfNeeded(
        client: any LLMClient, characterName: String, maxMessages: Int, maxAgeDays: Int
    ) async {
        // First, prune messages older than maxAgeDays
        let cutoffDate =
            Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date()
        let beforeCount = messages.count
        self.messages.removeAll { $0.timestamp < cutoffDate }
        if self.messages.count < beforeCount {
            logger.info(
                "Pruned \(beforeCount - self.messages.count) messages older than \(maxAgeDays) days for \(self.characterName)"
            )
        }

        guard messages.count > maxMessages else { return }

        let keepRecentCount = max(10, maxMessages / 3)
        let compactCount = messages.count - keepRecentCount
        guard compactCount > 0 else { return }

        let oldMessages = Array(messages.prefix(compactCount))
        let recentMessages = Array(messages.suffix(keepRecentCount))

        // Build a text representation of old messages for summarization
        var summaryInput = """
            Summarize this conversation history between \(characterName) and the user \
            in 2-3 short paragraphs. Capture the key topics, decisions, and emotional tone:\n\n
            """

        for msg in oldMessages {
            let role: String
            switch msg.role {
            case "assistant": role = characterName
            case "user": role = "User"
            default: role = "System"
            }
            let text = msg.content.compactMap(\.text).joined(separator: " ")
            if !text.isEmpty {
                summaryInput += "[\(role)]: \(text)\n"
            }
        }

        do {
            let response = try await client.sendMessage(
                messages: [LLMMessage.user(summaryInput)],
                systemPrompt: "You are a helpful assistant. Summarize the conversation concisely.",
                tools: nil,
                maxTokens: 500
            )

            if let summary = response.textContent {
                let summaryMessage = SessionMessage(
                    role: "user",
                    content: [
                        SessionContentBlock(
                            type: "text",
                            text: "[CONVERSATION SUMMARY]\n\(summary)",
                            toolName: nil,
                            toolCallId: nil
                        )
                    ],
                    timestamp: oldMessages.first?.timestamp ?? Date()
                )

                messages = [summaryMessage] + recentMessages
                save()
                logger.info(
                    "Compacted session for \(self.characterName): \(compactCount) messages → 1 summary + \(keepRecentCount) recent"
                )
            }
        } catch {
            logger.error(
                "Session compaction failed for \(self.characterName): \(error.localizedDescription)"
            )
            // On failure, just trim without summary to prevent unbounded growth
            messages = recentMessages
            save()
        }
    }

    // MARK: - Clear

    /// Clear the session (delete all messages and remove file from disk).
    func clear() {
        messages = []
        try? FileManager.default.removeItem(at: fileURL)
        logger.info("Cleared session for \(self.characterName)")
    }

    // MARK: - Private helpers

    /// JSON-encode a `[String: JSONValue]` dictionary into a string for storage.
    private func encodeArguments(_ args: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(args),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    /// Decode a JSON string back into a `[String: JSONValue]` dictionary.
    private func decodeArguments(_ json: String?) -> [String: JSONValue] {
        guard let json = json,
            let data = json.data(using: .utf8)
        else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }
}
