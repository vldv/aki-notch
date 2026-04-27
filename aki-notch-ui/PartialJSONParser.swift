//
//  PartialJSONParser.swift
//  aki-notch-ui
//
//  Incremental parser for extracting fields from partially-received
//  JSON tool call arguments during LLM streaming. Designed to extract
//  the `face` field as soon as it's complete and stream `message`
//  characters incrementally.
//

import Foundation

/// Extracts `face` and `message` fields from partially-received JSON.
///
/// During streaming, tool call arguments arrive as JSON fragments:
/// `{"face": "happy", "message": "Hel` → `lo! How` → ` are you?"}`
///
/// This parser tracks what's been extracted so far and reports new
/// characters as they become available.
struct PartialJSONParser: Sendable {

    /// Result of parsing partial JSON.
    struct ParseResult: Sendable {
        /// The face value, if fully extracted (e.g., "happy").
        let face: String?
        /// The message text extracted so far.
        let message: String?
        /// New message characters since the last parse (delta).
        let messageDelta: String?
    }

    /// The accumulated JSON string so far.
    private var accumulated: String = ""
    /// Previously extracted message length (to compute delta).
    private var lastMessageLength: Int = 0
    /// Cached face value once extracted.
    private var extractedFace: String?

    /// Feed new JSON fragment and extract available fields.
    ///
    /// - Parameter delta: New JSON characters to append.
    /// - Returns: Parse result with any newly-available data.
    mutating func feed(_ delta: String) -> ParseResult {
        accumulated += delta

        // Try to extract face if not yet found
        if extractedFace == nil {
            extractedFace = extractStringField("face", from: accumulated)
        }

        // Try to extract message (may be partial — the closing quote may be missing)
        let message = extractPartialStringField("message", from: accumulated)

        // Compute delta
        let messageDelta: String?
        if let message = message, message.count > lastMessageLength {
            messageDelta = String(message.dropFirst(lastMessageLength))
            lastMessageLength = message.count
        } else {
            messageDelta = nil
        }

        return ParseResult(
            face: extractedFace,
            message: message,
            messageDelta: messageDelta
        )
    }

    /// Reset the parser state.
    mutating func reset() {
        accumulated = ""
        lastMessageLength = 0
        extractedFace = nil
    }

    // MARK: - Field Extraction

    /// Extract a complete string field value from JSON.
    /// Returns nil if the field isn't found or the value isn't fully closed.
    private func extractStringField(_ key: String, from json: String) -> String? {
        // Look for "key": "value" pattern
        // Handle escaped quotes in the value
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }

        // Find the colon after the key
        let afterKey = json[keyRange.upperBound...]
        guard let colonIdx = afterKey.firstIndex(of: ":") else { return nil }

        // Find the opening quote of the value
        let afterColon = afterKey[afterKey.index(after: colonIdx)...]
            .drop(while: { $0.isWhitespace })
        guard afterColon.first == "\"" else { return nil }

        // Extract the string value, handling escaped quotes
        let valueStart = afterColon.index(after: afterColon.startIndex)
        var result = ""
        var i = valueStart
        while i < json.endIndex {
            let c = json[i]
            if c == "\\" {
                // Escaped character
                let next = json.index(after: i)
                if next < json.endIndex {
                    let escaped = json[next]
                    switch escaped {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    default: result.append(contentsOf: ["\\", escaped])
                    }
                    i = json.index(after: next)
                    continue
                }
            } else if c == "\"" {
                // Closing quote — field is complete
                return result
            }
            result.append(c)
            i = json.index(after: i)
        }

        // No closing quote found — field is incomplete
        return nil
    }

    /// Extract a potentially partial string field value.
    /// Unlike `extractStringField`, this returns the value even without a closing quote.
    /// Used for the `message` field where we want to stream characters as they arrive.
    private func extractPartialStringField(_ key: String, from json: String) -> String? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }

        let afterKey = json[keyRange.upperBound...]
        guard let colonIdx = afterKey.firstIndex(of: ":") else { return nil }

        let afterColon = afterKey[afterKey.index(after: colonIdx)...]
            .drop(while: { $0.isWhitespace })
        guard afterColon.first == "\"" else { return nil }

        let valueStart = afterColon.index(after: afterColon.startIndex)
        var result = ""
        var i = valueStart
        while i < json.endIndex {
            let c = json[i]
            if c == "\\" {
                let next = json.index(after: i)
                if next < json.endIndex {
                    let escaped = json[next]
                    switch escaped {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    default: result.append(contentsOf: ["\\", escaped])
                    }
                    i = json.index(after: next)
                    continue
                } else {
                    // Backslash at end — incomplete escape, don't include
                    break
                }
            } else if c == "\"" {
                // Closing quote
                return result
            }
            result.append(c)
            i = json.index(after: i)
        }

        // No closing quote — return what we have (partial)
        return result.isEmpty ? nil : result
    }
}
