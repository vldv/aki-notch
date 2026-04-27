//
//  AgentEvent.swift
//  aki-notch-ui
//
//  Typed events emitted by the agent loop for UI updates, logging,
//  and dataset recording. Inspired by pi-mono's agent event system.
//

import Foundation

/// Events emitted by the agent loop.
///
/// Consumers (UI, dataset logger, debug logger) subscribe to these events
/// to react to agent lifecycle changes without coupling to the loop internals.
enum AgentEvent: Sendable {
    // Agent lifecycle
    case agentStart
    case agentEnd(messages: [LLMMessage])

    // Turn lifecycle — a turn is one LLM call + any tool executions
    case turnStart(iteration: Int)
    case turnEnd(response: LLMResponse, toolResults: [ToolExecutionResult])

    // Message lifecycle
    case messageStart(message: LLMMessage)
    case messageEnd(message: LLMMessage)

    // Tool execution lifecycle
    case toolExecutionStart(toolCallId: String, toolName: String, arguments: [String: JSONValue])
    case toolExecutionEnd(toolCallId: String, toolName: String, result: String, isError: Bool)

    // Streaming lifecycle — emitted when the LLM client supports streaming
    case streamDelta(LLMStreamEvent)
}

/// Result of a single tool execution, for event reporting.
struct ToolExecutionResult: Sendable {
    let toolCallId: String
    let toolName: String
    let result: String
    let isError: Bool
}
