//
//  LLMStreamEvent.swift
//  aki-notch-ui
//
//  Event types emitted during LLM response streaming (SSE).
//  Both Anthropic and OpenAI streaming produce these unified events.
//

import Foundation

/// Events emitted during streaming of an LLM response.
///
/// The typical event sequence is:
/// 1. `start` — response has begun
/// 2. Interleaved `textDelta` and `toolCallDelta` events
/// 3. `toolCallEnd` for each completed tool call
/// 4. `done` or `error` — response is complete
enum LLMStreamEvent: Sendable {
    /// Response streaming has started.
    case start

    /// A chunk of text content arrived.
    case textDelta(String)

    /// A tool call has started (we know its name and ID).
    case toolCallStart(contentIndex: Int, id: String, name: String)

    /// A chunk of tool call arguments JSON arrived.
    /// `accumulatedArguments` is the full arguments string so far.
    case toolCallDelta(contentIndex: Int, argumentsDelta: String, accumulatedArguments: String)

    /// A tool call is complete with final parsed arguments.
    case toolCallEnd(contentIndex: Int, id: String, name: String, arguments: [String: JSONValue])

    /// The full response is complete.
    case done(response: LLMResponse)

    /// An error occurred during streaming.
    case error(message: String)
}
