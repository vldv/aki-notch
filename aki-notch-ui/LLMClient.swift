// LLMClient.swift
// aki-notch-ui

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "LLMClient")

// MARK: - JSONValue

/// A generic, provider-agnostic JSON value type used for tool inputs/outputs.
/// Replaces `AnthropicValue` with a fully `Codable`, `Equatable`, `Sendable` enum.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
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

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
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
        case .object(let v):
            try container.encode(v)
        case .null:
            try container.encodeNil()
        }
    }

    // MARK: Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Order matters: check null first, then Bool before Int/Double,
        // and Int before Double (every Int also decodes as Double).
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
        if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
            return
        }
        if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
            return
        }

        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unable to decode JSONValue"
            )
        )
    }
}

// MARK: - LLMContent

/// Provider-agnostic content block types that can appear in messages and responses.
enum LLMContent: Sendable {
    /// Plain text content.
    case text(String)
    /// Image content with raw data and MIME type (e.g. "image/png").
    case image(data: Data, mimeType: String)
    /// A tool invocation requested by the model.
    case toolUse(id: String, name: String, arguments: [String: JSONValue])
    /// The result of a tool invocation, sent back to the model.
    case toolResult(toolCallId: String, content: String, isError: Bool)
}

// MARK: - LLMMessage

/// A provider-agnostic conversation message.
struct LLMMessage: Sendable {

    enum Role: String, Sendable {
        case user
        case assistant
        case toolResult
    }

    let role: Role
    let content: [LLMContent]

    // MARK: Convenience initializers

    /// Create a simple text message from the user.
    static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }

    /// Create a user message with multiple content blocks (e.g. text + images).
    static func user(_ blocks: [LLMContent]) -> LLMMessage {
        LLMMessage(role: .user, content: blocks)
    }

    /// Create an assistant message with multiple content blocks.
    static func assistant(_ blocks: [LLMContent]) -> LLMMessage {
        LLMMessage(role: .assistant, content: blocks)
    }

    /// Create a single tool result message.
    static func toolResult(toolCallId: String, content: String, isError: Bool = false) -> LLMMessage
    {
        LLMMessage(
            role: .toolResult,
            content: [
                .toolResult(toolCallId: toolCallId, content: content, isError: isError)
            ])
    }

    /// Create a message containing multiple tool results (batched).
    static func toolResults(_ results: [(toolCallId: String, content: String, isError: Bool)])
        -> LLMMessage
    {
        LLMMessage(
            role: .toolResult,
            content: results.map { result in
                .toolResult(
                    toolCallId: result.toolCallId, content: result.content, isError: result.isError)
            })
    }
}

// MARK: - LLMUsage

/// Token usage information from an LLM response.
struct LLMUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int

    static let zero = LLMUsage(inputTokens: 0, outputTokens: 0)
}

// MARK: - LLMResponse

/// A provider-agnostic response from an LLM.
struct LLMResponse: Sendable {

    enum StopReason: String, Sendable {
        case stop
        case length
        case toolUse
        case error
    }

    let content: [LLMContent]
    let stopReason: StopReason
    let usage: LLMUsage
    let errorMessage: String?

    // MARK: Convenience extractors

    /// The text of the first `.text` content block, if any.
    var textContent: String? {
        for block in content {
            if case .text(let text) = block {
                return text
            }
        }
        return nil
    }

    /// All tool-use blocks extracted as a flat array of tuples.
    var toolCalls: [(id: String, name: String, arguments: [String: JSONValue])] {
        content.compactMap { block in
            if case .toolUse(let id, let name, let arguments) = block {
                return (id: id, name: name, arguments: arguments)
            }
            return nil
        }
    }
}

// MARK: - LLMToolDefinition

/// A provider-agnostic tool definition describing a function the model may call.
struct LLMToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: LLMToolParameters
}

/// The parameter schema for an LLM tool (always an "object" type at the top level).
struct LLMToolParameters: Sendable {
    /// Always "object".
    let type: String
    let properties: [String: LLMPropertySchema]
    let required: [String]
}

/// Schema for a single property within a tool's parameters.
struct LLMPropertySchema: Sendable {
    let type: String
    let description: String
    /// For array types, describes the schema of each element.
    private let _items: IndirectLLMPropertySchema?

    var items: LLMPropertySchema? { _items?.schema }

    init(type: String, description: String, items: LLMPropertySchema? = nil) {
        self.type = type
        self.description = description
        self._items = items.map { IndirectLLMPropertySchema($0) }
    }
}

/// Heap-allocated wrapper to break the value-type recursion in `LLMPropertySchema`.
final class IndirectLLMPropertySchema: @unchecked Sendable {
    let schema: LLMPropertySchema
    init(_ schema: LLMPropertySchema) { self.schema = schema }
}

// MARK: - LLMClient Protocol

/// Provider-agnostic protocol for sending messages to an LLM.
///
/// Concrete implementations (e.g. `AnthropicLLMClient`, `OpenAILLMClient`) translate
/// the generic types into provider-specific API calls.
protocol LLMClient: Sendable {

    /// Send a conversation to the LLM and return a response.
    ///
    /// - Parameters:
    ///   - messages: The conversation history.
    ///   - systemPrompt: A system-level instruction prepended to the conversation.
    ///   - tools: Optional tool definitions the model may invoke.
    ///   - maxTokens: Maximum number of tokens for the model's reply.
    /// - Returns: A provider-agnostic `LLMResponse`.
    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int
    ) async throws -> LLMResponse

    /// Whether this client supports streaming responses.
    var supportsStreaming: Bool { get }

    /// Stream a conversation response from the LLM, emitting events as content arrives.
    ///
    /// The returned stream emits `LLMStreamEvent`s as partial content arrives.
    /// The final event is always `.done(response:)` or `.error(message:)`.
    ///
    /// Default implementation falls back to `sendMessage()` and emits a single `.done`.
    ///
    /// - Parameters:
    ///   - messages: The conversation history.
    ///   - systemPrompt: A system-level instruction prepended to the conversation.
    ///   - tools: Optional tool definitions the model may invoke.
    ///   - maxTokens: Maximum number of tokens for the model's reply.
    /// - Returns: An `AsyncThrowingStream` of `LLMStreamEvent`.
    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

// MARK: - Default Streaming Implementation

extension LLMClient {

    var supportsStreaming: Bool { false }

    /// Default non-streaming fallback: calls `sendMessage()` and wraps the result
    /// in a single `.done` event.
    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await self.sendMessage(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        maxTokens: maxTokens
                    )
                    continuation.yield(.done(response: response))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(message: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Streaming URLSession (Delegate-based)

/// Add standard SSE headers to a URLRequest for streaming.
func applySSEHeaders(to request: inout URLRequest) {
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
}

/// Performs an HTTP request with delegate-based data delivery for true incremental streaming.
///
/// `URLSession.bytes(for:)` buffers at the HTTP/2 layer, defeating SSE streaming.
/// This helper uses `URLSessionDataDelegate` which receives data chunks as they arrive
/// from the network, with no buffering.
///
/// - Parameter request: The URLRequest to perform (should have SSE headers applied).
/// - Returns: A tuple of `(AsyncStream<Data>, HTTPURLResponse)`.
/// - Throws: On network errors or non-HTTP responses.
func performStreamingRequest(_ request: URLRequest) async throws -> (
    AsyncStream<Data>, HTTPURLResponse
) {
    let delegate = StreamingDelegate()
    let session = URLSession(
        configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            return config
        }(),
        delegate: delegate,
        delegateQueue: nil
    )

    let task = session.dataTask(with: request)

    let stream = AsyncStream<Data> { continuation in
        delegate.onData = { data in
            continuation.yield(data)
        }
        delegate.onComplete = { error in
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }

    task.resume()

    // Wait for the response headers before returning
    let response = await delegate.waitForResponse()

    guard let httpResponse = response else {
        throw AnthropicClientError.networkError(
            NSError(
                domain: "LLMClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No HTTP response received"]))
    }

    return (stream, httpResponse)
}

/// URLSessionDataDelegate that delivers data chunks incrementally without buffering.
private class StreamingDelegate: NSObject, URLSessionDataDelegate {
    var onData: ((Data) -> Void)?
    var onComplete: ((Error?) -> Void)?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse?, Never>?
    private var httpResponse: HTTPURLResponse?

    func waitForResponse() async -> HTTPURLResponse? {
        // If we already have a response (race condition), return it immediately
        if let response = httpResponse { return response }
        return await withCheckedContinuation { continuation in
            self.responseContinuation = continuation
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        httpResponse = http
        responseContinuation?.resume(returning: http)
        responseContinuation = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData?(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        // If response never arrived (e.g., connection error), resume with nil
        responseContinuation?.resume(returning: nil)
        responseContinuation = nil
        onComplete?(error)
    }
}

// MARK: - SSE Line Parser

/// Parses raw SSE (Server-Sent Events) data chunks into event/data pairs.
///
/// Both Anthropic and OpenAI use SSE for streaming. This utility handles
/// the line-based protocol: `event: <type>\ndata: <json>\n\n`.
enum SSELineParser {

    /// Parsed SSE event with optional event type and data payload.
    struct SSEEvent {
        let event: String?
        let data: String
    }

    /// Parse an async stream of `Data` chunks into SSE events.
    ///
    /// - Parameter dataStream: An `AsyncStream<Data>` from the delegate-based streaming helper.
    /// - Returns: An `AsyncStream` of parsed `SSEEvent`s.
    static func parse(dataStream: AsyncStream<Data>) -> AsyncStream<SSEEvent> {
        AsyncStream { continuation in
            Task {
                var currentEvent: String?
                var currentData: String = ""
                var lineBuffer: [UInt8] = []

                for await chunk in dataStream {
                    for byte in chunk {
                        if byte == 0x0A {  // newline
                            let line = String(bytes: lineBuffer, encoding: .utf8) ?? ""
                            lineBuffer.removeAll(keepingCapacity: true)

                            if line.isEmpty {
                                // Empty line = end of event
                                if !currentData.isEmpty {
                                    continuation.yield(
                                        SSEEvent(
                                            event: currentEvent,
                                            data: currentData
                                        ))
                                    currentEvent = nil
                                    currentData = ""
                                }
                            } else if line.hasPrefix("event: ") {
                                currentEvent = String(line.dropFirst(7))
                            } else if line.hasPrefix("data: ") {
                                let data = String(line.dropFirst(6))
                                if currentData.isEmpty {
                                    currentData = data
                                } else {
                                    currentData += "\n" + data
                                }
                            }
                            // Ignore other lines (comments, etc.)
                        } else if byte != 0x0D {  // skip \r
                            lineBuffer.append(byte)
                        }
                    }
                }

                // Flush any remaining event
                if !currentData.isEmpty {
                    continuation.yield(
                        SSEEvent(
                            event: currentEvent,
                            data: currentData
                        ))
                }

                continuation.finish()
            }
        }
    }
}

// MARK: - Image Helper

/// Detect the media type of image data by checking magic bytes.
///
/// Supports PNG, JPEG, GIF, and WebP detection. Falls back to `"image/png"`.
func detectLLMImageMediaType(_ data: Data) -> String {
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
    // WebP: RIFF....WEBP
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
