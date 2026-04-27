//
//  AgentTool.swift
//  aki-notch-ui
//
//  Protocol for agent tools. Each tool is a self-contained unit with
//  its own schema, execution mode, and implementation.
//  Inspired by pi-mono's AgentTool interface.
//

import Foundation

/// How a tool should be executed relative to other tools in the same batch.
enum ToolExecutionMode: Sendable {
    /// Tool must execute one at a time, in order. Use for UI-visible tools
    /// (send_overlay, send_chat, start_game) that need sequential display.
    case sequential

    /// Tool can execute concurrently with other parallel tools.
    /// Use for non-visual tools (save_memory, edit_memory, delete_memory).
    case parallel
}

/// Result returned by a tool execution.
struct AgentToolResult: Sendable {
    /// Text result returned to the LLM.
    let content: String

    /// Whether this result represents an error.
    let isError: Bool

    /// Hint that the agent should stop after the current tool batch.
    /// When true, the loop breaks immediately (used for hard dismiss).
    let terminate: Bool

    nonisolated init(content: String, isError: Bool = false, terminate: Bool = false) {
        self.content = content
        self.isError = isError
        self.terminate = terminate
    }

    /// Convenience for a successful result.
    static func success(_ content: String) -> AgentToolResult {
        AgentToolResult(content: content)
    }

    /// Convenience for an error result.
    static func error(_ content: String) -> AgentToolResult {
        AgentToolResult(content: content, isError: true)
    }

    /// Convenience for a result that should terminate the loop.
    static func terminate(_ content: String) -> AgentToolResult {
        AgentToolResult(content: content, terminate: true)
    }
}

/// Protocol that all agent tools must conform to.
///
/// Each tool declares its name, description, parameter schema, execution mode,
/// and an async `execute` method. The agent loop discovers tools via this protocol
/// and handles schema conversion, argument passing, and result collection.
///
/// Inspired by pi-mono's `AgentTool<TParameters>` interface.
protocol AgentTool: Sendable {
    /// Unique tool name (e.g., "send_overlay", "save_memory").
    var name: String { get }

    /// Human-readable description shown to the LLM.
    var description: String { get }

    /// JSON Schema for the tool's parameters.
    var parameters: LLMToolParameters { get }

    /// How this tool should be executed relative to others in the same batch.
    var executionMode: ToolExecutionMode { get }

    /// Execute the tool with the given arguments.
    ///
    /// - Parameters:
    ///   - arguments: Parsed tool arguments as a JSON value dictionary.
    /// - Returns: The tool result to send back to the LLM.
    func execute(arguments: [String: JSONValue]) async -> AgentToolResult
}

/// Extension to convert an array of `AgentTool` to `LLMToolDefinition` array.
extension Array where Element == any AgentTool {
    func toLLMToolDefinitions() -> [LLMToolDefinition] {
        map { tool in
            LLMToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            )
        }
    }
}
