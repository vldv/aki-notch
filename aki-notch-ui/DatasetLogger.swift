//
//  DatasetLogger.swift
//  aki-notch-ui
//
//  Opt-in JSONL logger for agent interactions. Accumulates training data
//  per character for future model fine-tuning. Subscribes to AgentEvent
//  lifecycle events and writes one JSON line per complete think() cycle.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "DatasetLogger")

/// Logs complete agent interaction cycles as JSONL for fine-tuning datasets.
///
/// Each line in the JSONL file represents one complete `think()` cycle with
/// the system prompt, all messages (user, assistant, tool results), and usage info.
/// Images are stripped (replaced with placeholders) to keep files manageable.
///
/// Files are stored at `~/.akiapp/datasets/<CharacterName>.jsonl`.
enum DatasetLogger {

    /// Log a complete interaction cycle for a character.
    ///
    /// - Parameters:
    ///   - characterName: The character's name (used for the filename).
    ///   - systemPrompt: The system prompt used for this cycle.
    ///   - messages: All messages from the interaction (from AgentLoopResult.messages).
    ///   - triggerContext: What triggered this interaction (e.g., "random", "compose — user message").
    ///   - model: The LLM model ID used.
    ///   - provider: The provider type (e.g., "anthropic", "openAICompatible").
    static func log(
        characterName: String,
        systemPrompt: String,
        messages: [LLMMessage],
        triggerContext: String,
        model: String,
        provider: String
    ) {
        // Build the dataset entry
        let entry = DatasetEntry(
            character: characterName,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            provider: provider,
            model: model,
            system_prompt: systemPrompt,
            messages: messages.map { convertMessage($0) },
            trigger_context: triggerContext
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // Deterministic output, no pretty print (JSONL)
        guard let data = try? encoder.encode(entry),
            let line = String(data: data, encoding: .utf8)
        else {
            logger.error("Failed to encode dataset entry for \(characterName)")
            return
        }

        // Append to file
        let fileURL = datasetFileURL(for: characterName)
        appendLine(line, to: fileURL)

        logger.info("Logged dataset entry for \(characterName) (\(messages.count) messages)")
    }

    // MARK: - File Management

    private static func datasetFileURL(for characterName: String) -> URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let datasetsDir =
            homeDir
            .appendingPathComponent(".akiapp", isDirectory: true)
            .appendingPathComponent("datasets", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: datasetsDir, withIntermediateDirectories: true)

        let safeName = characterName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return datasetsDir.appendingPathComponent("\(safeName).jsonl")
    }

    private static func appendLine(_ line: String, to url: URL) {
        let lineData = (line + "\n").data(using: .utf8)!

        if FileManager.default.fileExists(atPath: url.path) {
            // Append to existing file
            guard let handle = try? FileHandle(forWritingTo: url) else {
                logger.error("Failed to open dataset file for writing: \(url.lastPathComponent)")
                return
            }
            handle.seekToEndOfFile()
            handle.write(lineData)
            handle.closeFile()
        } else {
            // Create new file
            do {
                try lineData.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to create dataset file: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Message Conversion

    private static func convertMessage(_ message: LLMMessage) -> DatasetMessage {
        let content: DatasetMessageContent

        // Check if it's a simple text-only message
        if message.content.count == 1, case .text(let text) = message.content[0] {
            content = .text(text)
        } else {
            // Multiple blocks — convert each
            let blocks = message.content.map { convertContentBlock($0) }
            content = .blocks(blocks)
        }

        return DatasetMessage(role: message.role.rawValue, content: content)
    }

    private static func convertContentBlock(_ block: LLMContent) -> DatasetContentBlock {
        switch block {
        case .text(let text):
            return DatasetContentBlock(
                type: "text", text: text, name: nil, tool_use_id: nil, input: nil)
        case .image:
            return DatasetContentBlock(
                type: "image", text: "[image omitted]", name: nil, tool_use_id: nil, input: nil)
        case .toolUse(let id, let name, let arguments):
            return DatasetContentBlock(
                type: "tool_use", text: nil, name: name, tool_use_id: id, input: arguments)
        case .toolResult(let toolCallId, let resultContent, _):
            return DatasetContentBlock(
                type: "tool_result", text: resultContent, name: nil, tool_use_id: toolCallId,
                input: nil)
        }
    }
}

// MARK: - Codable Dataset Types

private struct DatasetEntry: Encodable {
    let character: String
    let timestamp: String
    let provider: String
    let model: String
    let system_prompt: String
    let messages: [DatasetMessage]
    let trigger_context: String
}

private struct DatasetMessage: Encodable {
    let role: String
    let content: DatasetMessageContent
}

/// Content is either a plain string (for simple text messages) or an array of blocks.
private enum DatasetMessageContent: Encodable {
    case text(String)
    case blocks([DatasetContentBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

private struct DatasetContentBlock: Encodable {
    let type: String
    let text: String?
    let name: String?  // tool name (for tool_use)
    let tool_use_id: String?  // tool call ID (for tool_use and tool_result)
    let input: [String: JSONValue]?  // tool arguments (for tool_use)
}
