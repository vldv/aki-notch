//
//  AgentLoop.swift
//  aki-notch-ui
//
//  Generic tool-use agent loop. Replaces the duplicated iteration logic
//  in AgentBrain and ConversationEngine.
//  Inspired by pi-mono's agentLoop.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "AgentLoop")

// MARK: - AgentLoopConfig

/// Configuration for an agent loop run.
struct AgentLoopConfig {
    /// The LLM client to use for this run.
    let client: any LLMClient

    /// System prompt for this run.
    let systemPrompt: String

    /// Maximum number of tool-use iterations before stopping.
    let maxIterations: Int

    /// Available tools for this run.
    let tools: [any AgentTool]

    /// Maximum tokens for each LLM response.
    let maxTokens: Int

    /// Optional transform applied to the full message list before each LLM call.
    /// Can be used to inject context (e.g., conversation transcript into system prompt)
    /// or prune old messages for context window management.
    var transformMessages: (@Sendable ([LLMMessage]) -> [LLMMessage])?

    /// Optional transform applied to the system prompt before each LLM call.
    /// Used by ConversationEngine to rebuild the system prompt with updated transcript.
    var transformSystemPrompt: (@Sendable (String) -> String)?

    init(
        client: any LLMClient,
        systemPrompt: String,
        maxIterations: Int = 20,
        tools: [any AgentTool],
        maxTokens: Int = 4096,
        transformMessages: (@Sendable ([LLMMessage]) -> [LLMMessage])? = nil,
        transformSystemPrompt: (@Sendable (String) -> String)? = nil
    ) {
        self.client = client
        self.systemPrompt = systemPrompt
        self.maxIterations = maxIterations
        self.tools = tools
        self.maxTokens = maxTokens
        self.transformMessages = transformMessages
        self.transformSystemPrompt = transformSystemPrompt
    }
}

// MARK: - AgentLoopResult

/// The final result of an agent loop run.
struct AgentLoopResult: Sendable {
    /// All messages exchanged during the loop (user, assistant, tool results).
    let messages: [LLMMessage]

    /// The last text content from the final assistant response, if any.
    /// Used for fallback text-only display when the LLM doesn't use tools.
    let lastTextContent: String?

    /// Whether the loop was terminated early by a tool.
    let terminated: Bool
}

// MARK: - AgentLoop

/// Generic, reusable tool-use agent loop.
///
/// Replaces the duplicated iteration logic in AgentBrain and ConversationEngine.
/// The loop calls the LLM, executes any tool calls in the response, feeds the
/// results back to the LLM, and repeats until the LLM stops calling tools or
/// `maxIterations` is reached.
enum AgentLoop {

    /// Run the agent loop.
    ///
    /// - Parameters:
    ///   - config: Loop configuration (client, tools, system prompt, etc.)
    ///   - initialMessages: The starting messages (typically one user message).
    ///   - onEvent: Callback for each agent event (for UI, logging, etc.).
    /// - Returns: The loop result with all accumulated messages.
    static func run(
        config: AgentLoopConfig,
        initialMessages: [LLMMessage],
        onEvent: ((AgentEvent) async -> Void)? = nil
    ) async throws -> AgentLoopResult {
        var messages = initialMessages
        var lastTextContent: String? = nil
        var terminated = false

        await onEvent?(.agentStart)

        // Emit initial messages
        for msg in initialMessages {
            await onEvent?(.messageStart(message: msg))
            await onEvent?(.messageEnd(message: msg))
        }

        // Convert tools to LLM definitions once (they don't change across iterations)
        let toolDefs = config.tools.toLLMToolDefinitions()

        for iteration in 1...config.maxIterations {
            await onEvent?(.turnStart(iteration: iteration))

            // Apply message transform if configured
            let llmMessages = config.transformMessages?(messages) ?? messages

            // Apply system prompt transform if configured
            let systemPrompt =
                config.transformSystemPrompt?(config.systemPrompt) ?? config.systemPrompt

            // Call the LLM — use streaming when available for faster UI feedback.
            let response: LLMResponse
            if config.client.supportsStreaming {
                response = try await streamResponse(
                    client: config.client,
                    messages: llmMessages,
                    systemPrompt: systemPrompt,
                    tools: toolDefs,
                    maxTokens: config.maxTokens,
                    onEvent: onEvent
                )
            } else {
                response = try await config.client.sendMessage(
                    messages: llmMessages,
                    systemPrompt: systemPrompt,
                    tools: toolDefs.isEmpty ? nil : toolDefs,
                    maxTokens: config.maxTokens
                )
            }

            // Extract tool calls and text content
            let toolCalls = response.toolCalls

            // Track last text content for fallback display
            if let text = response.textContent {
                lastTextContent = text
                logger.info("Text content received (\(text.count) chars)")
            }

            // If no tool calls, we're done
            if toolCalls.isEmpty {
                logger.info("No tool calls — ending loop at iteration \(iteration)")
                await onEvent?(.turnEnd(response: response, toolResults: []))
                break
            }

            // Tools were called — clear lastTextContent so fallback only fires
            // for a truly text-only final response
            lastTextContent = nil

            // Build the assistant message echoing back the response
            let assistantMessage = LLMMessage.assistant(response.content)
            messages.append(assistantMessage)
            await onEvent?(.messageStart(message: assistantMessage))
            await onEvent?(.messageEnd(message: assistantMessage))

            // Execute tools
            let toolResults = await executeToolCalls(
                toolCalls: toolCalls,
                tools: config.tools,
                onEvent: onEvent
            )

            // Build the tool-result message
            let resultMessage = LLMMessage.toolResults(
                toolResults.map {
                    (toolCallId: $0.toolCallId, content: $0.content, isError: $0.isError)
                }
            )
            messages.append(resultMessage)

            // Build execution results for the event
            let execResults = toolResults.map {
                ToolExecutionResult(
                    toolCallId: $0.toolCallId,
                    toolName: $0.toolName,
                    result: $0.content,
                    isError: $0.isError
                )
            }

            // Check for termination
            if toolResults.contains(where: { $0.terminate }) {
                terminated = true
                logger.info("Tool requested termination — ending loop")
                await onEvent?(.turnEnd(response: response, toolResults: execResults))
                break
            }

            // Emit message events for the tool-result message
            await onEvent?(.messageStart(message: resultMessage))
            await onEvent?(.messageEnd(message: resultMessage))

            await onEvent?(.turnEnd(response: response, toolResults: execResults))
        }

        await onEvent?(.agentEnd(messages: messages))

        return AgentLoopResult(
            messages: messages,
            lastTextContent: lastTextContent,
            terminated: terminated
        )
    }

    // MARK: - Tool Execution

    /// Internal struct for tracking per-tool execution results.
    private struct ToolCallResult {
        let toolCallId: String
        let toolName: String
        let content: String
        let isError: Bool
        let terminate: Bool
    }

    /// Execute a batch of tool calls, respecting execution modes.
    ///
    /// If any tool in the batch is `.sequential`, ALL tools run sequentially.
    /// Otherwise, parallel tools can execute concurrently.
    private static func executeToolCalls(
        toolCalls: [(id: String, name: String, arguments: [String: JSONValue])],
        tools: [any AgentTool],
        onEvent: ((AgentEvent) async -> Void)?
    ) async -> [ToolCallResult] {
        // Check if any tool requires sequential execution
        let hasSequential = toolCalls.contains { call in
            tools.first { $0.name == call.name }?.executionMode == .sequential
        }

        if hasSequential || toolCalls.count == 1 {
            return await executeToolCallsSequential(
                toolCalls: toolCalls, tools: tools, onEvent: onEvent)
        } else {
            return await executeToolCallsParallel(
                toolCalls: toolCalls, tools: tools, onEvent: onEvent)
        }
    }

    private static func executeToolCallsSequential(
        toolCalls: [(id: String, name: String, arguments: [String: JSONValue])],
        tools: [any AgentTool],
        onEvent: ((AgentEvent) async -> Void)?
    ) async -> [ToolCallResult] {
        var results: [ToolCallResult] = []

        for call in toolCalls {
            await onEvent?(
                .toolExecutionStart(
                    toolCallId: call.id, toolName: call.name, arguments: call.arguments))

            let tool = tools.first { $0.name == call.name }
            let result: AgentToolResult

            if let tool = tool {
                result = await tool.execute(arguments: call.arguments)
            } else {
                result = .error("Unknown tool '\(call.name)'.")
            }

            logger.info("Tool \(call.name) → \(result.content.prefix(120))")
            await onEvent?(
                .toolExecutionEnd(
                    toolCallId: call.id, toolName: call.name, result: result.content,
                    isError: result.isError))

            results.append(
                ToolCallResult(
                    toolCallId: call.id,
                    toolName: call.name,
                    content: result.content,
                    isError: result.isError,
                    terminate: result.terminate
                ))

            // If a sequential tool terminates, stop executing remaining tools
            if result.terminate { break }
        }

        return results
    }

    private static func executeToolCallsParallel(
        toolCalls: [(id: String, name: String, arguments: [String: JSONValue])],
        tools: [any AgentTool],
        onEvent: ((AgentEvent) async -> Void)?
    ) async -> [ToolCallResult] {
        // Emit start events for all tools first
        for call in toolCalls {
            await onEvent?(
                .toolExecutionStart(
                    toolCallId: call.id, toolName: call.name, arguments: call.arguments))
        }

        // Pre-resolve tools outside the TaskGroup to avoid nonisolated property access warnings.
        let resolvedTools:
            [(
                index: Int, call: (id: String, name: String, arguments: [String: JSONValue]),
                tool: (any AgentTool)?
            )] =
                toolCalls.enumerated().map { (index, call) in
                    let tool = tools.first { $0.name == call.name }
                    return (index: index, call: call, tool: tool)
                }

        // Execute in parallel using TaskGroup
        let results = await withTaskGroup(of: (Int, ToolCallResult).self) { group in
            for entry in resolvedTools {
                let call = entry.call
                let tool = entry.tool
                let index = entry.index
                group.addTask {
                    let result: AgentToolResult
                    if let tool = tool {
                        result = await tool.execute(arguments: call.arguments)
                    } else {
                        result = AgentToolResult(
                            content: "Unknown tool '\(call.name)'.", isError: true)
                    }
                    return (
                        index,
                        ToolCallResult(
                            toolCallId: call.id,
                            toolName: call.name,
                            content: result.content,
                            isError: result.isError,
                            terminate: result.terminate
                        )
                    )
                }
            }

            var indexed: [(Int, ToolCallResult)] = []
            for await result in group {
                indexed.append(result)
            }
            // Sort back to original order
            return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        // Emit end events in original order
        for result in results {
            logger.info("Tool \(result.toolName) → \(result.content.prefix(120))")
            await onEvent?(
                .toolExecutionEnd(
                    toolCallId: result.toolCallId, toolName: result.toolName,
                    result: result.content, isError: result.isError))
        }

        return results
    }

    // MARK: - Streaming Helper

    /// Stream an LLM response, emitting `streamDelta` events for UI integration,
    /// and return the final accumulated `LLMResponse` when complete.
    private static func streamResponse(
        client: any LLMClient,
        messages: [LLMMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        maxTokens: Int,
        onEvent: ((AgentEvent) async -> Void)?
    ) async throws -> LLMResponse {
        let stream = client.streamMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools.isEmpty ? nil : tools,
            maxTokens: maxTokens
        )

        var finalResponse: LLMResponse?

        for try await event in stream {
            // Forward every stream event to the caller for UI integration
            await onEvent?(.streamDelta(event))

            switch event {
            case .done(let response):
                finalResponse = response
            case .error(let message):
                throw AnthropicClientError.serverError(
                    status: 0, message: "Stream error: \(message)")
            default:
                break  // Other events are forwarded but don't affect the loop
            }
        }

        // If we got a final response from the stream, return it
        if let response = finalResponse {
            return response
        }

        // Fallback: stream ended without a .done event — fall back to non-streaming
        logger.warning(
            "Stream ended without .done event — falling back to non-streaming")
        return try await client.sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools.isEmpty ? nil : tools,
            maxTokens: maxTokens
        )
    }
}
