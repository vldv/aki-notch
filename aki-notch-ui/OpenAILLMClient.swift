//
//  OpenAILLMClient.swift
//  aki-notch-ui
//
//  OpenAI Chat Completions API client conforming to the provider-agnostic
//  `LLMClient` protocol. Works with OpenAI, together.ai, Ollama, LM Studio,
//  and any other OpenAI-compatible endpoint.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "OpenAILLMClient")

// MARK: - OpenAI Request Types

private struct OpenAIRequest: Encodable {
    let model: String
    let max_tokens: Int
    let messages: [OpenAIMessage]
    let tools: [OpenAITool]?
}

private struct OpenAIStreamRequest: Encodable {
    let model: String
    let max_tokens: Int
    let messages: [OpenAIMessage]
    let tools: [OpenAITool]?
    let stream: Bool
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: OpenAIContent?
    let tool_calls: [OpenAIToolCall]?
    let tool_call_id: String?
    let name: String?

    // Omit nil keys from the JSON to keep payloads clean and avoid confusing
    // providers that are strict about unexpected fields.
    enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, name
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        // For assistant messages with tool_calls but no text, encode content as
        // explicit JSON null (some providers require the key to be present).
        if role == "assistant" {
            if let content = content {
                try container.encode(content, forKey: .content)
            } else {
                try container.encodeNil(forKey: .content)
            }
        } else if let content = content {
            try container.encode(content, forKey: .content)
        }

        if let toolCalls = tool_calls, !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .tool_calls)
        }
        if let toolCallId = tool_call_id {
            try container.encode(toolCallId, forKey: .tool_call_id)
        }
        if let name = name {
            try container.encode(name, forKey: .name)
        }
    }
}

/// Content that encodes as a plain JSON string when it's simple text, or as an
/// array of content-part objects when it includes images.
private enum OpenAIContent: Encodable {
    case text(String)
    case parts([OpenAIContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private struct OpenAIContentPart: Encodable {
    let type: String
    let text: String?
    let image_url: OpenAIImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text, image_url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if let text = text {
            try container.encode(text, forKey: .text)
        }
        if let imageURL = image_url {
            try container.encode(imageURL, forKey: .image_url)
        }
    }
}

private struct OpenAIImageURL: Encodable {
    let url: String  // "data:image/png;base64,..."
}

private struct OpenAIToolCall: Codable {
    let id: String
    let type: String  // "function"
    let function: OpenAIFunctionCall
}

private struct OpenAIFunctionCall: Codable {
    let name: String
    let arguments: String  // JSON-encoded string
}

private struct OpenAITool: Encodable {
    let type: String  // "function"
    let function: OpenAIFunctionDef
}

private struct OpenAIFunctionDef: Encodable {
    let name: String
    let description: String
    let parameters: OpenAIFunctionParams
}

private struct OpenAIFunctionParams: Encodable {
    let type: String  // "object"
    let properties: [String: OpenAIPropertySchema]
    let required: [String]
}

/// Schema for a single property. Uses a wrapper class for the recursive
/// `items` field so that the struct can reference itself indirectly (Swift
/// structs can't contain themselves inline).
private struct OpenAIPropertySchema: Encodable {
    let type: String
    let description: String
    private let _items: IndirectPropertySchema?

    var items: OpenAIPropertySchema? { _items?.schema }

    init(type: String, description: String, items: OpenAIPropertySchema? = nil) {
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
        if let items = _items {
            try container.encode(items, forKey: .items)
        }
    }
}

private class IndirectPropertySchema: Encodable {
    let schema: OpenAIPropertySchema
    init(_ schema: OpenAIPropertySchema) { self.schema = schema }
    func encode(to encoder: Encoder) throws { try schema.encode(to: encoder) }
}

// MARK: - OpenAI Response Types

private struct OpenAIResponse: Decodable {
    let id: String?
    let choices: [OpenAIChoice]?
    let usage: OpenAIUsage?
}

private struct OpenAIChoice: Decodable {
    let message: OpenAIResponseMessage?
    let finish_reason: String?
}

private struct OpenAIResponseMessage: Decodable {
    let role: String?
    let content: String?
    let tool_calls: [OpenAIToolCall]?
}

private struct OpenAIUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
}

struct OpenAIErrorResponse: Decodable {
    let error: OpenAIErrorDetail?
}

struct OpenAIErrorDetail: Decodable {
    let message: String?
    let type: String?
}

// MARK: - OpenAI Streaming Response Types

private struct OpenAIStreamChunk: Decodable {
    let id: String?
    let choices: [OpenAIStreamChoice]?
    let usage: OpenAIStreamUsage?
}

private struct OpenAIStreamChoice: Decodable {
    let index: Int?
    let delta: OpenAIStreamDelta?
    let finish_reason: String?
}

private struct OpenAIStreamDelta: Decodable {
    let role: String?
    let content: String?
    let tool_calls: [OpenAIStreamToolCall]?
}

private struct OpenAIStreamToolCall: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: OpenAIStreamFunction?
}

private struct OpenAIStreamFunction: Decodable {
    let name: String?
    let arguments: String?
}

private struct OpenAIStreamUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
}

// MARK: - OpenAILLMClient

/// OpenAI Chat Completions client implementing the provider-agnostic `LLMClient` protocol.
///
/// Works with any OpenAI-compatible endpoint (OpenAI, Together AI, Ollama, LM Studio, etc.).
final class OpenAILLMClient: LLMClient, @unchecked Sendable {

    let baseURL: String
    let apiKey: String
    let model: String
    private let session: URLSession

    /// Create an OpenAI-compatible LLM client.
    ///
    /// - Parameters:
    ///   - apiKey: Bearer token for the API.
    ///   - model: Model identifier, e.g. `"gpt-4o"`, `"meta-llama/..."`.
    ///   - baseURL: Base URL **without** trailing slash. The client appends `/v1/chat/completions`.
    init(apiKey: String, model: String, baseURL: String) {
        self.apiKey = apiKey
        self.model = model
        // Strip any trailing slashes for consistency.
        self.baseURL =
            baseURL.hasSuffix("/")
            ? String(baseURL.dropLast())
            : baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - LLMClient conformance

    var supportsStreaming: Bool { true }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int
    ) async throws -> LLMResponse {

        // 1. Build the URL.
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw AnthropicClientError.serverError(
                status: 0, message: "Invalid base URL: \(baseURL)")
        }

        // 2. Construct the URLRequest.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // 3. Convert LLM types → OpenAI wire types.
        var openAIMessages: [OpenAIMessage] = []

        // System prompt → first message.
        if !systemPrompt.isEmpty {
            openAIMessages.append(
                OpenAIMessage(
                    role: "system",
                    content: .text(systemPrompt),
                    tool_calls: nil,
                    tool_call_id: nil,
                    name: nil
                )
            )
        }

        // Conversation messages.
        for message in messages {
            openAIMessages.append(contentsOf: convertMessage(message))
        }

        // Tool definitions.
        let openAITools: [OpenAITool]? = tools.flatMap { defs in
            let mapped = defs.map { convertToolDefinition($0) }
            return mapped.isEmpty ? nil : mapped
        }

        // 4. Encode request body.
        let body = OpenAIRequest(
            model: model,
            max_tokens: maxTokens,
            messages: openAIMessages,
            tools: openAITools
        )

        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw AnthropicClientError.decodingError(error)
        }

        // 5. Send with retry logic.
        return try await sendWithRetry(request: request, maxRetries: 3)
    }

    // MARK: - Retry Logic

    private func sendWithRetry(
        request: URLRequest,
        maxRetries: Int
    ) async throws -> LLMResponse {

        let retryableServerStatuses: Set<Int> = [500, 502, 503]
        var lastError: AnthropicClientError?

        for attempt in 0...maxRetries {
            // Back off before retries.
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
                    "Retry attempt \(attempt)/\(maxRetries) after \(sleepSeconds)s (error: \(error.localizedDescription))"
                )
                try await Task.sleep(nanoseconds: sleepSeconds * 1_000_000_000)
            }

            // Perform network call.
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                let networkError = AnthropicClientError.networkError(error)
                lastError = networkError
                if attempt < maxRetries { continue }
                throw networkError
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AnthropicClientError.networkError(
                    NSError(
                        domain: "OpenAILLMClient",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Response is not HTTP"]
                    )
                )
            }

            let statusCode = httpResponse.statusCode

            switch statusCode {
            case 200:
                // Decode and convert to LLMResponse.
                do {
                    let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                    return convertResponse(decoded)
                } catch {
                    logger.error("Failed to decode OpenAI response: \(error.localizedDescription)")
                    // Log the raw body for debugging.
                    if let rawBody = String(data: data, encoding: .utf8) {
                        logger.debug("Raw response body: \(rawBody)")
                    }
                    throw AnthropicClientError.decodingError(error)
                }

            case 401:
                throw AnthropicClientError.invalidAPIKey

            case 429:
                let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")
                let rateLimitError = AnthropicClientError.rateLimited(retryAfter: retryAfter)
                lastError = rateLimitError
                if attempt < maxRetries { continue }
                throw rateLimitError

            default:
                let message: String
                if let apiError = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data),
                    let errorMsg = apiError.error?.message
                {
                    message = errorMsg
                } else {
                    message = String(data: data, encoding: .utf8) ?? "Unknown error"
                }
                let serverError = AnthropicClientError.serverError(
                    status: statusCode, message: message)

                if retryableServerStatuses.contains(statusCode) {
                    lastError = serverError
                    if attempt < maxRetries { continue }
                }
                throw serverError
            }
        }

        throw lastError
            ?? AnthropicClientError.serverError(status: 0, message: "Unexpected retry loop exit")
    }

    // MARK: - Message Conversion (LLM → OpenAI)

    /// Convert a single `LLMMessage` into one or more `OpenAIMessage`s.
    ///
    /// Tool-result messages expand into one OpenAI message per result block,
    /// because the OpenAI format expects each `role: "tool"` message to carry
    /// exactly one `tool_call_id`.
    private func convertMessage(_ message: LLMMessage) -> [OpenAIMessage] {
        switch message.role {
        case .user:
            return [convertUserMessage(message.content)]

        case .assistant:
            return [convertAssistantMessage(message.content)]

        case .toolResult:
            return convertToolResultMessage(message.content)
        }
    }

    private func convertUserMessage(_ content: [LLMContent]) -> OpenAIMessage {
        // Check if there are any images — if so, we need the multipart content format.
        let hasImages = content.contains { block in
            if case .image = block { return true }
            return false
        }

        if !hasImages {
            // Simple text-only message.
            let text = content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n")

            return OpenAIMessage(
                role: "user",
                content: .text(text),
                tool_calls: nil,
                tool_call_id: nil,
                name: nil
            )
        }

        // Multi-part: text + images.
        var parts: [OpenAIContentPart] = []
        for block in content {
            switch block {
            case .text(let text):
                parts.append(
                    OpenAIContentPart(type: "text", text: text, image_url: nil)
                )
            case .image(let data, let mimeType):
                let base64 = data.base64EncodedString()
                let dataURL = "data:\(mimeType);base64,\(base64)"
                parts.append(
                    OpenAIContentPart(
                        type: "image_url",
                        text: nil,
                        image_url: OpenAIImageURL(url: dataURL)
                    )
                )
            default:
                break  // Ignore tool-related blocks in user messages.
            }
        }

        return OpenAIMessage(
            role: "user",
            content: .parts(parts),
            tool_calls: nil,
            tool_call_id: nil,
            name: nil
        )
    }

    private func convertAssistantMessage(_ content: [LLMContent]) -> OpenAIMessage {
        var textPieces: [String] = []
        var toolCalls: [OpenAIToolCall] = []

        for block in content {
            switch block {
            case .text(let text):
                textPieces.append(text)

            case .toolUse(let id, let name, let arguments):
                // Encode the arguments dict to a JSON string.
                let argsString = encodeJSONValueDict(arguments)
                toolCalls.append(
                    OpenAIToolCall(
                        id: id,
                        type: "function",
                        function: OpenAIFunctionCall(
                            name: name,
                            arguments: argsString
                        )
                    )
                )

            default:
                break
            }
        }

        let textContent: OpenAIContent? =
            textPieces.isEmpty
            ? nil
            : .text(textPieces.joined(separator: "\n"))

        return OpenAIMessage(
            role: "assistant",
            content: textContent,
            tool_calls: toolCalls.isEmpty ? nil : toolCalls,
            tool_call_id: nil,
            name: nil
        )
    }

    /// Each tool result content block becomes a separate `role: "tool"` message.
    private func convertToolResultMessage(_ content: [LLMContent]) -> [OpenAIMessage] {
        var messages: [OpenAIMessage] = []
        for block in content {
            if case .toolResult(let toolCallId, let resultContent, _) = block {
                messages.append(
                    OpenAIMessage(
                        role: "tool",
                        content: .text(resultContent),
                        tool_calls: nil,
                        tool_call_id: toolCallId,
                        name: nil
                    )
                )
            }
        }
        return messages
    }

    // MARK: - Tool Definition Conversion

    private func convertToolDefinition(_ def: LLMToolDefinition) -> OpenAITool {
        var properties: [String: OpenAIPropertySchema] = [:]
        for (key, prop) in def.parameters.properties {
            properties[key] = convertPropertySchema(prop)
        }

        return OpenAITool(
            type: "function",
            function: OpenAIFunctionDef(
                name: def.name,
                description: def.description,
                parameters: OpenAIFunctionParams(
                    type: "object",
                    properties: properties,
                    required: def.parameters.required
                )
            )
        )
    }

    private func convertPropertySchema(_ schema: LLMPropertySchema) -> OpenAIPropertySchema {
        OpenAIPropertySchema(
            type: schema.type,
            description: schema.description,
            items: schema.items.map { convertPropertySchema($0) }
        )
    }

    // MARK: - Response Conversion (OpenAI → LLM)

    private func convertResponse(_ response: OpenAIResponse) -> LLMResponse {
        guard let choice = response.choices?.first,
            let message = choice.message
        else {
            // Empty or malformed response — return an error response.
            return LLMResponse(
                content: [],
                stopReason: .error,
                usage: .zero,
                errorMessage: "OpenAI response contained no choices"
            )
        }

        var contentBlocks: [LLMContent] = []

        // Text content.
        if let text = message.content, !text.isEmpty {
            contentBlocks.append(.text(text))
        }

        // Tool calls.
        if let toolCalls = message.tool_calls {
            for call in toolCalls {
                let arguments = decodeJSONStringToDict(call.function.arguments)
                contentBlocks.append(
                    .toolUse(
                        id: call.id,
                        name: call.function.name,
                        arguments: arguments
                    )
                )
            }
        }

        // Stop reason.
        let stopReason: LLMResponse.StopReason
        switch choice.finish_reason {
        case "stop":
            stopReason = .stop
        case "tool_calls":
            stopReason = .toolUse
        case "length":
            stopReason = .length
        default:
            // If there are tool calls, infer toolUse even if finish_reason is unexpected.
            if message.tool_calls != nil && !(message.tool_calls?.isEmpty ?? true) {
                stopReason = .toolUse
            } else {
                stopReason = .stop
            }
        }

        // Usage.
        let usage = LLMUsage(
            inputTokens: response.usage?.prompt_tokens ?? 0,
            outputTokens: response.usage?.completion_tokens ?? 0
        )

        return LLMResponse(
            content: contentBlocks,
            stopReason: stopReason,
            usage: usage,
            errorMessage: nil
        )
    }

    // MARK: - JSON Helpers

    // MARK: - Streaming

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performOpenAIStream(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                } catch {
                    continuation.yield(.error(message: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func performOpenAIStream(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        // 1. Build URL
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw AnthropicClientError.serverError(
                status: 0, message: "Invalid base URL: \(baseURL)")
        }

        // 2. Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applySSEHeaders(to: &request)

        // 3. Convert messages
        var openAIMessages: [OpenAIMessage] = []
        if !systemPrompt.isEmpty {
            openAIMessages.append(
                OpenAIMessage(
                    role: "system",
                    content: .text(systemPrompt),
                    tool_calls: nil,
                    tool_call_id: nil,
                    name: nil
                )
            )
        }
        for message in messages {
            openAIMessages.append(contentsOf: convertMessage(message))
        }

        let openAITools: [OpenAITool]? = tools.flatMap { defs in
            let mapped = defs.map { convertToolDefinition($0) }
            return mapped.isEmpty ? nil : mapped
        }

        // 4. Encode body with stream: true
        let body = OpenAIStreamRequest(
            model: model,
            max_tokens: maxTokens,
            messages: openAIMessages,
            tools: openAITools,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        // 5. Make delegate-based streaming request (no HTTP/2 buffering)
        let (dataStream, httpResponse) = try await performStreamingRequest(request)

        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for await chunk in dataStream {
                errorBody += String(data: chunk, encoding: .utf8) ?? ""
            }
            throw AnthropicClientError.serverError(
                status: httpResponse.statusCode,
                message: errorBody
            )
        }

        // 6. Parse SSE events
        continuation.yield(.start)

        var accumulatedText = ""
        var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var inputTokens = 0
        var outputTokens = 0
        var stopReason: String?

        for await sseEvent in SSELineParser.parse(dataStream: dataStream) {
            let data = sseEvent.data

            if data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                break
            }

            guard let jsonData = data.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: jsonData)
            else { continue }

            // Extract usage if present
            if let usage = chunk.usage {
                inputTokens = usage.prompt_tokens ?? inputTokens
                outputTokens = usage.completion_tokens ?? outputTokens
            }

            guard let choice = chunk.choices?.first else { continue }

            if let reason = choice.finish_reason {
                stopReason = reason
            }

            let delta = choice.delta

            // Text content delta
            if let content = delta?.content {
                accumulatedText += content
                continuation.yield(.textDelta(content))
            }

            // Tool call deltas
            if let toolCallDeltas = delta?.tool_calls {
                for tc in toolCallDeltas {
                    let idx = tc.index ?? 0

                    // New tool call
                    if let id = tc.id, let name = tc.function?.name {
                        toolCalls[idx] = (id: id, name: name, arguments: "")
                        continuation.yield(.toolCallStart(contentIndex: idx, id: id, name: name))
                    }

                    // Arguments delta
                    if let argsDelta = tc.function?.arguments, !argsDelta.isEmpty {
                        if var existing = toolCalls[idx] {
                            existing.arguments += argsDelta
                            toolCalls[idx] = existing
                            continuation.yield(
                                .toolCallDelta(
                                    contentIndex: idx,
                                    argumentsDelta: argsDelta,
                                    accumulatedArguments: existing.arguments
                                ))
                        }
                    }
                }
            }
        }

        // 7. Build final response
        var contentBlocks: [LLMContent] = []

        if !accumulatedText.isEmpty {
            contentBlocks.append(.text(accumulatedText))
        }

        for idx in toolCalls.keys.sorted() {
            let tc = toolCalls[idx]!
            let args = decodeJSONStringToDict(tc.arguments)
            contentBlocks.append(.toolUse(id: tc.id, name: tc.name, arguments: args))
            continuation.yield(
                .toolCallEnd(contentIndex: idx, id: tc.id, name: tc.name, arguments: args))
        }

        let llmStopReason: LLMResponse.StopReason
        switch stopReason {
        case "stop": llmStopReason = .stop
        case "tool_calls": llmStopReason = .toolUse
        case "length": llmStopReason = .length
        default:
            llmStopReason =
                contentBlocks.contains(where: {
                    if case .toolUse = $0 { return true }
                    return false
                }) ? .toolUse : .stop
        }

        let finalResponse = LLMResponse(
            content: contentBlocks,
            stopReason: llmStopReason,
            usage: LLMUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            errorMessage: nil
        )

        continuation.yield(.done(response: finalResponse))
        continuation.finish()
    }

    /// Encode a `[String: JSONValue]` dictionary to a compact JSON string for tool-call arguments.
    private func encodeJSONValueDict(_ dict: [String: JSONValue]) -> String {
        // Convert JSONValue dict → Foundation types, then serialize.
        let foundationDict = dict.mapValues { jsonValueToAny($0) }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: foundationDict,
                options: [.sortedKeys]
            )
        else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decode a JSON string (from an OpenAI tool-call `arguments` field) into `[String: JSONValue]`.
    private func decodeJSONStringToDict(_ jsonString: String) -> [String: JSONValue] {
        guard let data = jsonString.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any]
        else {
            logger.warning("Failed to parse tool call arguments: \(jsonString)")
            return [:]
        }
        return dict.mapValues { anyToJSONValue($0) }
    }

    /// Convert a `JSONValue` to a Foundation `Any` for `JSONSerialization`.
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        }
    }

    /// Convert a Foundation `Any` (from `JSONSerialization`) to `JSONValue`.
    private func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String:
            return .string(s)
        case let b as Bool:
            // Must check Bool before NSNumber/Int/Double because Bool bridges to NSNumber.
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return .double(d)
        case let arr as [Any]:
            return .array(arr.map { anyToJSONValue($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { anyToJSONValue($0) })
        case is NSNull:
            return .null
        default:
            // Fallback: coerce to string.
            return .string("\(value)")
        }
    }
}
