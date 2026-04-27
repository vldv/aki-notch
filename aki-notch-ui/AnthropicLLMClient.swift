//
//  AnthropicLLMClient.swift
//  aki-notch-ui
//
//  Adapter that wraps the existing `AnthropicClient` to conform to the
//  provider-agnostic `LLMClient` protocol.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "AnthropicLLMClient")

/// Adapter that wraps the existing `AnthropicClient` to conform to `LLMClient`.
///
/// All HTTP/retry logic remains in `AnthropicClient`; this class is a pure
/// type-translation layer between the provider-agnostic `LLM*` types and
/// the Anthropic-specific request/response types.
final class AnthropicLLMClient: LLMClient, @unchecked Sendable {

    private let client: AnthropicClient

    // MARK: - Initializers

    init(client: AnthropicClient) {
        self.client = client
    }

    /// Convenience initializer matching the common construction pattern.
    init(
        apiKey: String,
        model: String = "claude-sonnet-4-20250514",
        baseURL: String = "https://api.anthropic.com",
        authStyle: AnthropicClient.AuthStyle = .xApiKey
    ) {
        self.client = AnthropicClient(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            authStyle: authStyle
        )
    }

    // MARK: - LLMClient conformance

    var supportsStreaming: Bool { true }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int
    ) async throws -> LLMResponse {
        // 1. Convert LLMMessage[] → AnthropicMessage[]
        let anthropicMessages = messages.map { convertToAnthropicMessage($0) }

        // 2. Convert LLMToolDefinition[] → AnthropicTool[]
        let anthropicTools = tools?.map { convertToAnthropicTool($0) }

        // 3. Delegate to the underlying Anthropic client
        let response = try await client.sendMessage(
            messages: anthropicMessages,
            systemPrompt: systemPrompt,
            tools: anthropicTools,
            maxTokens: maxTokens
        )

        // 4. Convert AnthropicResponse → LLMResponse
        return convertFromAnthropicResponse(response)
    }

    // MARK: - Message conversion (LLM → Anthropic)

    private func convertToAnthropicMessage(_ message: LLMMessage) -> AnthropicMessage {
        let role: String
        switch message.role {
        case .user:
            role = "user"
        case .assistant:
            role = "assistant"
        case .toolResult:
            // Tool results are sent as the "user" role in the Anthropic API.
            role = "user"
        }

        let content: AnthropicContent

        switch message.role {
        case .user:
            // Optimise: single text block → bare string content.
            if message.content.count == 1, case .text(let text) = message.content[0] {
                content = .text(text)
            } else {
                content = .blocks(message.content.map { convertToContentBlock($0) })
            }

        case .assistant:
            // Assistant messages always use blocks (they may contain tool_use).
            content = .blocks(message.content.map { convertToContentBlock($0) })

        case .toolResult:
            // Each content item should be a .toolResult; wrap in toolResult blocks.
            content = .blocks(message.content.map { convertToContentBlock($0) })
        }

        return AnthropicMessage(role: role, content: content)
    }

    private func convertToContentBlock(_ llmContent: LLMContent) -> ContentBlock {
        switch llmContent {
        case .text(let text):
            return .text(TextBlock(type: "text", text: text))

        case .image(let data, let mimeType):
            let base64String = data.base64EncodedString()
            let source = ImageSourceBlock(
                type: "base64",
                media_type: mimeType,
                data: base64String
            )
            return .image(ImageBlock(type: "image", source: source))

        case .toolUse(let id, let name, let arguments):
            let anthropicInput = convertJSONValueDictToAnthropicValueDict(arguments)
            return .toolUse(
                ToolUseBlock(
                    type: "tool_use",
                    id: id,
                    name: name,
                    input: anthropicInput
                ))

        case .toolResult(let toolCallId, let resultContent, _):
            return .toolResult(
                ToolResultBlock(
                    type: "tool_result",
                    tool_use_id: toolCallId,
                    content: resultContent
                ))
        }
    }

    // MARK: - Tool definition conversion (LLM → Anthropic)

    private func convertToAnthropicTool(_ tool: LLMToolDefinition) -> AnthropicTool {
        let properties = tool.parameters.properties.mapValues {
            convertToAnthropicPropertySchema($0)
        }
        let schema = AnthropicToolSchema(
            type: tool.parameters.type,
            properties: properties,
            required: tool.parameters.required
        )
        return AnthropicTool(
            name: tool.name,
            description: tool.description,
            input_schema: schema
        )
    }

    private func convertToAnthropicPropertySchema(_ schema: LLMPropertySchema)
        -> AnthropicPropertySchema
    {
        let items: AnthropicPropertySchema? = schema.items.map {
            convertToAnthropicPropertySchema($0)
        }
        return AnthropicPropertySchema(
            type: schema.type,
            description: schema.description,
            items: items
        )
    }

    // MARK: - Response conversion (Anthropic → LLM)

    private func convertFromAnthropicResponse(_ response: AnthropicResponse) -> LLMResponse {
        let content: [LLMContent] = response.content.map { block in
            switch block {
            case .text(let text):
                return .text(text)
            case .toolUse(let id, let name, let input):
                let arguments = convertAnthropicValueDictToJSONValueDict(input)
                return .toolUse(id: id, name: name, arguments: arguments)
            }
        }

        let stopReason: LLMResponse.StopReason
        switch response.stop_reason {
        case "end_turn":
            stopReason = .stop
        case "tool_use":
            stopReason = .toolUse
        case "max_tokens":
            stopReason = .length
        default:
            stopReason = .stop
        }

        let usage = LLMUsage(
            inputTokens: response.usage?.input_tokens ?? 0,
            outputTokens: response.usage?.output_tokens ?? 0
        )

        return LLMResponse(
            content: content,
            stopReason: stopReason,
            usage: usage,
            errorMessage: nil
        )
    }

    // MARK: - JSONValue ↔ AnthropicValue conversion

    private func convertJSONValueDictToAnthropicValueDict(
        _ dict: [String: JSONValue]
    ) -> [String: AnthropicValue] {
        dict.mapValues { convertJSONValueToAnthropicValue($0) }
    }

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
                    try await self.performAnthropicStream(
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

    private enum StreamBlock {
        case text(String)
        case toolUse(id: String, name: String, arguments: String)
    }

    private func performAnthropicStream(
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]?,
        maxTokens: Int,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        // 1. Build URL
        guard let url = URL(string: "\(client.baseURL)/v1/messages") else {
            throw AnthropicClientError.serverError(
                status: 0, message: "Invalid base URL: \(client.baseURL)")
        }

        // 2. Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        switch client.authStyle {
        case .xApiKey:
            request.setValue(client.apiKey, forHTTPHeaderField: "x-api-key")
        case .bearer:
            request.setValue("Bearer \(client.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        applySSEHeaders(to: &request)

        // 3. Build body with stream: true
        let anthropicMessages = messages.map { convertToAnthropicMessage($0) }
        let anthropicTools = tools?.map { convertToAnthropicTool($0) }

        let body = AnthropicStreamRequest(
            model: client.model,
            max_tokens: maxTokens,
            system: systemPrompt,
            tools: anthropicTools,
            tool_choice: anthropicTools != nil ? .sequential : nil,
            messages: anthropicMessages,
            stream: true
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        // 4. Start the delegate-based stream (no HTTP/2 buffering)
        let (dataStream, httpResponse) = try await performStreamingRequest(request)

        guard httpResponse.statusCode == 200 else {
            // Read error body from stream
            var errorBody = ""
            for await chunk in dataStream {
                errorBody += String(data: chunk, encoding: .utf8) ?? ""
            }
            throw AnthropicClientError.serverError(
                status: httpResponse.statusCode,
                message: errorBody
            )
        }

        // 5. Parse SSE events
        continuation.yield(.start)

        var inputTokens = 0
        var outputTokens = 0
        var stopReason: String?
        var contentBlocks: [Int: StreamBlock] = [:]
        let decoder = JSONDecoder()

        for await sseEvent in SSELineParser.parse(dataStream: dataStream) {
            guard let data = sseEvent.data.data(using: .utf8) else { continue }

            // Decode the type field first
            guard let baseEvent = try? decoder.decode(SSEBaseEvent.self, from: data) else {
                continue
            }

            switch baseEvent.type {
            case "message_start":
                if let parsed = try? decoder.decode(SSEMessageStart.self, from: data) {
                    inputTokens = parsed.message.usage?.input_tokens ?? 0
                    outputTokens = parsed.message.usage?.output_tokens ?? 0
                }

            case "content_block_start":
                if let parsed = try? decoder.decode(SSEContentBlockStart.self, from: data) {
                    let idx = parsed.index
                    switch parsed.content_block.type {
                    case "text":
                        contentBlocks[idx] = .text("")
                    case "tool_use":
                        let id = parsed.content_block.id ?? ""
                        let name = parsed.content_block.name ?? ""
                        contentBlocks[idx] = .toolUse(id: id, name: name, arguments: "")
                        continuation.yield(
                            .toolCallStart(contentIndex: idx, id: id, name: name))
                    default:
                        break
                    }
                }

            case "content_block_delta":
                if let parsed = try? decoder.decode(SSEContentBlockDelta.self, from: data) {
                    let idx = parsed.index
                    switch parsed.delta.type {
                    case "text_delta":
                        let text = parsed.delta.text ?? ""
                        if case .text(let acc) = contentBlocks[idx] {
                            contentBlocks[idx] = .text(acc + text)
                        }
                        continuation.yield(.textDelta(text))

                    case "input_json_delta":
                        let partial = parsed.delta.partial_json ?? ""
                        if case .toolUse(let id, let name, let acc) = contentBlocks[idx] {
                            let newAcc = acc + partial
                            contentBlocks[idx] = .toolUse(id: id, name: name, arguments: newAcc)
                            continuation.yield(
                                .toolCallDelta(
                                    contentIndex: idx,
                                    argumentsDelta: partial,
                                    accumulatedArguments: newAcc
                                ))
                        }

                    default:
                        break
                    }
                }

            case "content_block_stop":
                if let parsed = try? decoder.decode(SSEContentBlockStop.self, from: data) {
                    let idx = parsed.index
                    if case .toolUse(let id, let name, let argsString) = contentBlocks[idx] {
                        var arguments: [String: JSONValue] = [:]
                        if let argsData = argsString.data(using: .utf8),
                            let parsed = try? decoder.decode(
                                [String: JSONValue].self, from: argsData)
                        {
                            arguments = parsed
                        }
                        continuation.yield(
                            .toolCallEnd(
                                contentIndex: idx, id: id, name: name, arguments: arguments
                            ))
                    }
                }

            case "message_delta":
                if let parsed = try? decoder.decode(SSEMessageDelta.self, from: data) {
                    stopReason = parsed.delta.stop_reason
                    if let out = parsed.usage?.output_tokens {
                        outputTokens = out
                    }
                }

            case "message_stop":
                // Build final response
                let sortedIndices = contentBlocks.keys.sorted()
                let content: [LLMContent] = sortedIndices.compactMap { idx in
                    switch contentBlocks[idx]! {
                    case .text(let t):
                        return .text(t)
                    case .toolUse(let id, let name, let argsString):
                        var arguments: [String: JSONValue] = [:]
                        if let argsData = argsString.data(using: .utf8),
                            let parsed = try? decoder.decode(
                                [String: JSONValue].self, from: argsData)
                        {
                            arguments = parsed
                        }
                        return .toolUse(id: id, name: name, arguments: arguments)
                    }
                }

                let llmStopReason: LLMResponse.StopReason
                switch stopReason {
                case "end_turn": llmStopReason = .stop
                case "tool_use": llmStopReason = .toolUse
                case "max_tokens": llmStopReason = .length
                default: llmStopReason = .stop
                }

                let finalResponse = LLMResponse(
                    content: content,
                    stopReason: llmStopReason,
                    usage: LLMUsage(inputTokens: inputTokens, outputTokens: outputTokens),
                    errorMessage: nil
                )
                continuation.yield(.done(response: finalResponse))
                continuation.finish()
                return

            default:
                break
            }
        }

        // If we exit the loop without message_stop, finish anyway
        continuation.finish()
    }

    // MARK: - Streaming request type

    private struct AnthropicStreamRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let tools: [AnthropicTool]?
        let tool_choice: AnthropicToolChoice?
        let messages: [AnthropicMessage]
        let stream: Bool
    }

    // MARK: - SSE JSON Decodable types

    private struct SSEBaseEvent: Decodable {
        let type: String
    }

    private struct SSEMessageStart: Decodable {
        let message: SSEMessageStartPayload
    }

    private struct SSEMessageStartPayload: Decodable {
        let usage: SSEUsage?
    }

    private struct SSEContentBlockStart: Decodable {
        let index: Int
        let content_block: SSEContentBlockInfo
    }

    private struct SSEContentBlockInfo: Decodable {
        let type: String
        let id: String?
        let name: String?
    }

    private struct SSEContentBlockDelta: Decodable {
        let index: Int
        let delta: SSEDeltaPayload
    }

    private struct SSEDeltaPayload: Decodable {
        let type: String?
        let text: String?
        let partial_json: String?
        let stop_reason: String?
    }

    private struct SSEContentBlockStop: Decodable {
        let index: Int
    }

    private struct SSEMessageDelta: Decodable {
        let delta: SSEDeltaPayload
        let usage: SSEUsage?
    }

    private struct SSEUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
    }

    private func convertJSONValueToAnthropicValue(_ value: JSONValue) -> AnthropicValue {
        switch value {
        case .string(let v):
            return .string(v)
        case .int(let v):
            return .int(v)
        case .double(let v):
            return .double(v)
        case .bool(let v):
            return .bool(v)
        case .array(let v):
            return .array(v.map { convertJSONValueToAnthropicValue($0) })
        case .object:
            // AnthropicValue has no .object case; the Anthropic API uses
            // [String: AnthropicValue] dictionaries directly at the top level.
            // Nested objects shouldn't typically appear in tool arguments,
            // but if they do, encode as a JSON string as a safe fallback.
            logger.warning(
                "JSONValue.object encountered in value conversion — encoding as JSON string fallback"
            )
            if let data = try? JSONEncoder().encode(value),
                let str = String(data: data, encoding: .utf8)
            {
                return .string(str)
            }
            return .null
        case .null:
            return .null
        }
    }

    private func convertAnthropicValueDictToJSONValueDict(
        _ dict: [String: AnthropicValue]
    ) -> [String: JSONValue] {
        dict.mapValues { convertAnthropicValueToJSONValue($0) }
    }

    private func convertAnthropicValueToJSONValue(_ value: AnthropicValue) -> JSONValue {
        switch value {
        case .string(let v):
            return .string(v)
        case .int(let v):
            return .int(v)
        case .double(let v):
            return .double(v)
        case .bool(let v):
            return .bool(v)
        case .array(let v):
            return .array(v.map { convertAnthropicValueToJSONValue($0) })
        case .null:
            return .null
        }
    }
}
