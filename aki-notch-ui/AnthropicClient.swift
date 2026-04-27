//
//  AnthropicClient.swift
//  aki-notch-ui
//
//  Async HTTP client for Anthropic's Messages API with tool-use support.
//

import Foundation
import os

// MARK: - Request Models

/// Top-level request body sent to the Anthropic Messages API.
struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let tools: [AnthropicTool]?
    let tool_choice: AnthropicToolChoice?
    let messages: [AnthropicMessage]
}

/// Controls how the model selects tools.
struct AnthropicToolChoice: Encodable {
    let type: String  // "auto", "any", or "tool"
    let disable_parallel_tool_use: Bool?

    /// Allow the model to decide, but only one tool per turn.
    static let sequential = AnthropicToolChoice(
        type: "auto",
        disable_parallel_tool_use: true
    )
}

/// Describes a tool the model may invoke.
struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let input_schema: AnthropicToolSchema
}

/// JSON Schema object that describes a tool's expected input.
struct AnthropicToolSchema: Encodable {
    let type: String  // always "object"
    let properties: [String: AnthropicPropertySchema]
    let required: [String]
}

/// Schema for an individual property inside a tool's input.
/// Uses `Indirect` wrapper to avoid recursive value type.
struct AnthropicPropertySchema: Encodable {
    let type: String  // "string", "integer", "array", etc.
    let description: String
    private let _items: IndirectPropertySchema?  // non-nil for array types

    var items: AnthropicPropertySchema? { _items?.schema }

    init(type: String, description: String, items: AnthropicPropertySchema? = nil) {
        self.type = type
        self.description = description
        self._items = items.map { IndirectPropertySchema($0) }
    }

    enum CodingKeys: String, CodingKey {
        case type, description, items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(_items?.schema, forKey: .items)
    }
}

/// Heap-allocated box to break the recursive value-type cycle in `AnthropicPropertySchema`.
/// Uses a concrete type instead of a generic class to work around a Swift 6.2 compiler crash
/// (SIL verification failure for generic class deinit under -O + WMO + strict concurrency).
private final class IndirectPropertySchema: Encodable {
    let schema: AnthropicPropertySchema
    init(_ schema: AnthropicPropertySchema) { self.schema = schema }
    func encode(to encoder: Encoder) throws { try schema.encode(to: encoder) }
}

// MARK: - Message & Content Models

/// A single message in the conversation (user or assistant turn).
struct AnthropicMessage: Codable {
    let role: String  // "user" or "assistant"
    let content: AnthropicContent
}

/// Content can be a plain string **or** an array of structured content blocks.
///
/// When encoding:
///   - `.text` encodes as a bare JSON string.
///   - `.blocks` encodes as a JSON array.
///
/// When decoding the reverse heuristic is applied (try string first, then array).
enum AnthropicContent: Codable {
    case text(String)
    case blocks([ContentBlock])

    // MARK: Encoding

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }

    // MARK: Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try plain string first.
        if let string = try? container.decode(String.self) {
            self = .text(string)
            return
        }
        // Fall back to array of content blocks.
        if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
            return
        }
        throw DecodingError.typeMismatch(
            AnthropicContent.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a String or [ContentBlock]"
            )
        )
    }
}

/// A single content block inside a message. Discriminated by the `type` field.
enum ContentBlock: Codable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case image(ImageBlock)

    // MARK: Coding keys shared across variants

    private enum TypeKey: String, CodingKey {
        case type
    }

    // MARK: Encoding

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        case .image(let block):
            try block.encode(to: encoder)
        }
    }

    // MARK: Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try TextBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultBlock(from: decoder))
        case "image":
            self = .image(try ImageBlock(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }
}

/// A plain-text content block.
struct TextBlock: Codable {
    let type: String  // "text"
    let text: String
}

/// A tool-use content block produced by the assistant.
struct ToolUseBlock: Codable {
    let type: String  // "tool_use"
    let id: String
    let name: String
    let input: [String: AnthropicValue]
}

/// A tool-result content block sent by the user after executing a tool.
struct ToolResultBlock: Codable {
    let type: String  // "tool_result"
    let tool_use_id: String
    let content: String
}

/// Source data for an image content block.
struct ImageSourceBlock: Codable {
    let type: String  // "base64"
    let media_type: String  // "image/png", "image/jpeg", etc.
    let data: String  // base64-encoded image data
}

/// An image content block.
struct ImageBlock: Codable {
    let type: String  // "image"
    let source: ImageSourceBlock
}

/// Detect the media type of image data by checking magic bytes.
func detectImageMediaType(_ data: Data) -> String {
    guard data.count >= 4 else { return "image/png" }
    let bytes = [UInt8](data.prefix(4))
    // PNG: 89 50 4E 47
    if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
        return "image/png"
    }
    // JPEG: FF D8 FF
    if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        return "image/jpeg"
    }
    // GIF: 47 49 46
    if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
        return "image/gif"
    }
    // WebP: 52 49 46 46 (RIFF) + offset 8-11 = WEBP
    if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
        if data.count >= 12 {
            let webpBytes = [UInt8](data[8..<12])
            if webpBytes == [0x57, 0x45, 0x42, 0x50] {
                return "image/webp"
            }
        }
    }
    return "image/png"  // default fallback
}

// MARK: - Lightweight JSON Value

/// A lightweight, `Codable` JSON value type used for tool inputs/outputs.
enum AnthropicValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnthropicValue])
    case null

    // MARK: Convenience accessors

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var arrayValue: [AnthropicValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    // MARK: Encoding

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .bool(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .null:
            try container.encodeNil()
        }
    }

    // MARK: Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Order matters: Int before Double (every Int also decodes as Double).
        if container.decodeNil() {
            self = .null
            return
        }
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
            return
        }
        if let v = try? container.decode(Int.self) {
            self = .int(v)
            return
        }
        if let v = try? container.decode(Double.self) {
            self = .double(v)
            return
        }
        if let v = try? container.decode(String.self) {
            self = .string(v)
            return
        }
        if let v = try? container.decode([AnthropicValue].self) {
            self = .array(v)
            return
        }

        throw DecodingError.typeMismatch(
            AnthropicValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unable to decode AnthropicValue"
            )
        )
    }
}

// MARK: - Response Models

/// Top-level response returned by the Anthropic Messages API.
struct AnthropicResponse: Decodable {
    let id: String
    let type: String
    let role: String
    let content: [ResponseContentBlock]
    let stop_reason: String?
    let usage: AnthropicUsage?
}

/// A content block in the API response (text or tool_use).
enum ResponseContentBlock: Decodable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AnthropicValue])

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode([String: AnthropicValue].self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown response content block type: \(type)"
            )
        }
    }
}

/// Token usage information included in the API response.
struct AnthropicUsage: Decodable {
    let input_tokens: Int?
    let output_tokens: Int?
}

// MARK: - Error Models

/// Error body returned by the Anthropic API on non-200 responses.
struct AnthropicError: Decodable {
    let type: String
    let error: AnthropicErrorDetail
}

/// Detailed error information nested inside `AnthropicError`.
struct AnthropicErrorDetail: Decodable {
    let type: String
    let message: String
}

// MARK: - Client Errors

/// Errors that `AnthropicClient` may throw.
enum AnthropicClientError: LocalizedError {
    case invalidAPIKey
    case rateLimited(retryAfter: String?)
    case serverError(status: Int, message: String)
    case networkError(Error)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid or missing Anthropic API key."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited by Anthropic API. Retry after \(retryAfter) seconds."
            }
            return "Rate limited by Anthropic API."
        case .serverError(let status, let message):
            return "Anthropic API error (HTTP \(status)): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode Anthropic API response: \(error.localizedDescription)"
        }
    }
}

// MARK: - Client

/// Async HTTP client for the Anthropic Messages API.
///
/// Usage:
/// ```
/// let client = AnthropicClient(apiKey: "sk-ant-...")
/// let response = try await client.sendMessage(
///     messages: [AnthropicMessage(role: "user", content: .text("Hello!"))],
///     systemPrompt: "You are a helpful assistant."
/// )
/// ```
final class AnthropicClient {

    /// How to authenticate with the API endpoint.
    enum AuthStyle {
        /// Anthropic-native: sends `x-api-key` header.
        case xApiKey
        /// Azure / proxy: sends `Authorization: Bearer` header.
        case bearer
    }

    /// Base URL for the Anthropic API (no trailing slash).
    let baseURL: String
    /// Secret API key used for authentication.
    let apiKey: String
    /// Model identifier, e.g. `"claude-sonnet-4-20250514"`.
    let model: String
    /// Authentication style to use when calling the API.
    let authStyle: AuthStyle

    /// Shared URL session configured with appropriate timeouts for tool-use responses.
    private let session: URLSession

    /// Logger for retry and diagnostic messages.
    private let logger = Logger(subsystem: "com.aki-notch-ui", category: "AnthropicClient")

    init(
        apiKey: String,
        model: String = "claude-sonnet-4-20250514",
        baseURL: String = "https://api.anthropic.com",
        authStyle: AuthStyle = .xApiKey
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.authStyle = authStyle

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    /// Send a list of messages to the Anthropic Messages API and return the parsed response.
    ///
    /// - Parameters:
    ///   - messages: The conversation messages to send.
    ///   - systemPrompt: A system-level instruction prepended to the conversation.
    ///   - tools: Optional array of tool definitions the model may call.
    ///   - maxTokens: Maximum number of tokens for the model's reply (default 4096).
    /// - Returns: A decoded `AnthropicResponse`.
    /// - Throws: `AnthropicClientError` on failure.
    func sendMessage(
        messages: [AnthropicMessage],
        systemPrompt: String,
        tools: [AnthropicTool]? = nil,
        maxTokens: Int = 4096,
        modelOverride: String? = nil,
        maxRetries: Int = 3
    ) async throws -> AnthropicResponse {
        // 1. Build the URL.
        guard let url = URL(string: "\(baseURL)/v1/messages") else {
            throw AnthropicClientError.serverError(
                status: 0, message: "Invalid base URL: \(baseURL)")
        }

        // 2. Construct the URLRequest.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        switch authStyle {
        case .xApiKey:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // 3. Encode the request body.
        let body = AnthropicRequest(
            model: modelOverride ?? model,
            max_tokens: maxTokens,
            system: systemPrompt,
            tools: tools,
            tool_choice: tools != nil ? .sequential : nil,
            messages: messages
        )

        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw AnthropicClientError.decodingError(error)
        }

        // 4. Perform the network request with retry logic.
        let retryableServerStatuses: Set<Int> = [500, 502, 503, 529]
        var lastError: AnthropicClientError?

        for attempt in 0...maxRetries {
            // If this is a retry, wait with exponential backoff before the attempt.
            if attempt > 0, let error = lastError {
                let backoffSeconds: Double = pow(2.0, Double(attempt))  // 2, 4, 8
                let sleepSeconds: UInt64

                if case .rateLimited(let retryAfter) = error,
                    let retryAfterStr = retryAfter,
                    let retryAfterValue = Double(retryAfterStr)
                {
                    sleepSeconds = UInt64(max(retryAfterValue, backoffSeconds))
                } else {
                    sleepSeconds = UInt64(backoffSeconds)
                }

                logger.info(
                    "Retry attempt \(attempt)/\(maxRetries) after \(sleepSeconds)s delay (error: \(error.localizedDescription))"
                )
                try await Task.sleep(nanoseconds: sleepSeconds * 1_000_000_000)
            }

            // 4a. Perform the network request.
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                let networkError = AnthropicClientError.networkError(error)
                lastError = networkError
                if attempt < maxRetries {
                    continue  // Retry on network errors.
                }
                throw networkError
            }

            // 4b. Validate the HTTP status code.
            guard let httpResponse = response as? HTTPURLResponse else {
                let error = AnthropicClientError.networkError(
                    NSError(
                        domain: "AnthropicClient", code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Response is not an HTTP response."
                        ])
                )
                throw error
            }

            let statusCode = httpResponse.statusCode

            // 4c. Handle well-known error codes.
            switch statusCode {
            case 200:
                // Success – decode and return.
                do {
                    let decoder = JSONDecoder()
                    return try decoder.decode(AnthropicResponse.self, from: data)
                } catch {
                    throw AnthropicClientError.decodingError(error)
                }

            case 401:
                throw AnthropicClientError.invalidAPIKey  // Never retry auth errors.

            case 429:
                let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                let rateLimitError = AnthropicClientError.rateLimited(retryAfter: retryAfter)
                lastError = rateLimitError
                if attempt < maxRetries {
                    continue  // Retry on rate limits.
                }
                throw rateLimitError

            default:
                // Attempt to decode a structured error body.
                let message: String
                if let apiError = try? JSONDecoder().decode(AnthropicError.self, from: data) {
                    message = apiError.error.message
                } else {
                    message = String(data: data, encoding: .utf8) ?? "Unknown error"
                }
                let serverError = AnthropicClientError.serverError(
                    status: statusCode, message: message)

                // Only retry on specific transient server error codes.
                if retryableServerStatuses.contains(statusCode) {
                    lastError = serverError
                    if attempt < maxRetries {
                        continue
                    }
                }
                throw serverError
            }
        }

        // This should be unreachable, but satisfies the compiler.
        throw lastError
            ?? AnthropicClientError.serverError(status: 0, message: "Unexpected retry loop exit")
    }
}
