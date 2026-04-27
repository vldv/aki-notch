//
//  LLMClientResolver.swift
//  aki-notch-ui
//
//  Shared utility for resolving an LLMClient from a character's
//  LLM configuration. Updated to use the provider-agnostic LLMClient
//  protocol — OpenAI-compatible providers now get a real OpenAILLMClient
//  instead of being routed through the Anthropic client.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "LLMClientResolver")

/// Result of resolving an LLM client for a character.
struct ResolvedLLMClient {
    let client: any LLMClient
    let model: String
}

/// Shared helper that reads a character's `llm.json`, finds the matching
/// provider in the store, and constructs a ready-to-use `LLMClient`.
///
/// Both `AgentBrain` and `ConversationEngine` delegate to this instead of
/// each carrying their own copy of the resolution logic.
@MainActor
enum LLMClientResolver {

    /// Resolve the `LLMClient` and model for a character based on its
    /// per-character LLM config and the available providers.
    ///
    /// - Parameters:
    ///   - character: The character whose `llm.json` should be read.
    ///   - providerStore: The store of configured LLM providers.
    /// - Returns: A `ResolvedLLMClient` on success, or `nil` if no usable
    ///   provider / API key is available.
    static func resolve(
        for character: Character,
        providerStore: ProviderStore
    ) -> ResolvedLLMClient? {
        let llmConfig = CharacterLLMConfig.load(from: character.directoryURL)

        // Find the provider (use the character's configured one, or fall back to first available).
        let provider: LLMProvider?
        if let providerID = llmConfig.providerID {
            provider = providerStore.provider(withID: providerID)
        } else {
            provider = providerStore.providers.first
        }

        guard let provider = provider,
            let apiKey = provider.apiKey, !apiKey.isEmpty
        else {
            logger.warning("No valid provider found for character \(character.name)")
            return nil
        }

        let model = llmConfig.modelID ?? "claude-sonnet-4-20250514"

        let client: any LLMClient

        switch provider.providerType {
        case .anthropic:
            // Native Anthropic API — uses x-api-key header.
            client = AnthropicLLMClient(
                apiKey: apiKey,
                model: model,
                baseURL: provider.apiBaseURL,
                authStyle: .xApiKey
            )

        case .azureAnthropic:
            // Azure-hosted Anthropic — same wire format, Bearer auth.
            client = AnthropicLLMClient(
                apiKey: apiKey,
                model: model,
                baseURL: provider.apiBaseURL,
                authStyle: .bearer
            )

        case .openAICompatible:
            // Real OpenAI Chat Completions format — works with OpenAI, Ollama,
            // LM Studio, vLLM, and any OpenAI-compatible endpoint.
            client = OpenAILLMClient(
                apiKey: apiKey,
                model: model,
                baseURL: provider.apiBaseURL
            )
        }

        logger.info(
            "Resolved \(provider.providerType.rawValue) client for \(character.name) — model: \(model)"
        )

        return ResolvedLLMClient(client: client, model: model)
    }
}
