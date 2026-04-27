import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "LLMProvider")

// MARK: - Provider Model

/// Represents a configured LLM provider (e.g. Anthropic, OpenAI-compatible).
final class LLMProvider: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var name: String
    @Published var apiBaseURL: String
    @Published var apiKeyRef: String
    @Published var providerType: ProviderType

    enum ProviderType: String, Codable, CaseIterable {
        case anthropic
        case azureAnthropic
        case openAICompatible
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, name, apiBaseURL, apiKeyRef, providerType
    }

    init(name: String, apiBaseURL: String, providerType: ProviderType) {
        self.id = UUID()
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.providerType = providerType
        self.apiKeyRef = "provider.\(self.id.uuidString).apiKey"
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.apiBaseURL = try container.decode(String.self, forKey: .apiBaseURL)
        self.apiKeyRef = try container.decode(String.self, forKey: .apiKeyRef)
        self.providerType = try container.decode(ProviderType.self, forKey: .providerType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(apiBaseURL, forKey: .apiBaseURL)
        try container.encode(apiKeyRef, forKey: .apiKeyRef)
        try container.encode(providerType, forKey: .providerType)
    }

    // MARK: Keychain helpers

    /// The actual API key value, loaded from Keychain.
    var apiKey: String? {
        KeychainHelper.load(key: apiKeyRef)
    }

    /// Save an API key to Keychain for this provider.
    func setApiKey(_ key: String) {
        KeychainHelper.save(key: apiKeyRef, value: key)
        objectWillChange.send()
    }

    /// Delete the API key from Keychain.
    func deleteApiKey() {
        KeychainHelper.delete(key: apiKeyRef)
        objectWillChange.send()
    }
}

// MARK: - ProviderStore

/// Manages persistence of LLM providers to disk.
@MainActor
final class ProviderStore: ObservableObject {
    @Published var providers: [LLMProvider] = []

    private let storageURL: URL

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let appDir = homeDir.appendingPathComponent(".akiapp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create .akiapp directory: \(error.localizedDescription)")
        }
        self.storageURL = appDir.appendingPathComponent("providers.json")

        load()

        if providers.isEmpty {
            let anthropic = LLMProvider(
                name: "Anthropic",
                apiBaseURL: "https://api.anthropic.com",
                providerType: .anthropic
            )
            providers.append(anthropic)
            save()
            logger.info("Seeded default Anthropic provider \(anthropic.id.uuidString)")
        }
    }

    // MARK: Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([LLMProvider].self, from: data)
            self.providers = decoded
            logger.info("Loaded \(decoded.count) provider(s) from disk")
        } catch {
            logger.error("Failed to load providers: \(error.localizedDescription)")
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(providers)
            try data.write(to: storageURL, options: .atomic)
            logger.info("Saved \(self.providers.count) provider(s) to disk")
        } catch {
            logger.error("Failed to save providers: \(error.localizedDescription)")
        }
    }

    func addProvider(name: String, baseURL: String, type: LLMProvider.ProviderType) -> LLMProvider {
        let p = LLMProvider(name: name, apiBaseURL: baseURL, providerType: type)
        providers.append(p)
        save()
        logger.info("Added provider \(p.name) (\(p.id.uuidString))")
        return p
    }

    func deleteProvider(_ provider: LLMProvider) {
        provider.deleteApiKey()
        providers.removeAll { $0.id == provider.id }
        save()
        logger.info("Deleted provider \(provider.name) (\(provider.id.uuidString))")
    }

    func provider(withID id: UUID) -> LLMProvider? {
        providers.first { $0.id == id }
    }
}

// MARK: - ModelListService

/// Fetches available models from a provider's API.
enum ModelListService {

    /// Fetch available models from a provider. Returns an array of model ID strings.
    static func fetchModels(provider: LLMProvider) async throws -> [String] {
        guard let apiKey = provider.apiKey, !apiKey.isEmpty else {
            throw ModelListError.noAPIKey
        }

        switch provider.providerType {
        case .anthropic:
            return try await fetchAnthropicModels(baseURL: provider.apiBaseURL, apiKey: apiKey)
        case .azureAnthropic:
            return try await fetchAzureAnthropicModels(baseURL: provider.apiBaseURL, apiKey: apiKey)
        case .openAICompatible:
            return try await fetchOpenAIModels(baseURL: provider.apiBaseURL, apiKey: apiKey)
        }
    }

    // MARK: Anthropic

    /// Anthropic: GET /v1/models → { "data": [{ "id": "claude-sonnet-4-20250514", ... }] }
    private static func fetchAnthropicModels(baseURL: String, apiKey: String) async throws
        -> [String]
    {
        guard let url = URL(string: "\(baseURL)/v1/models") else {
            throw ModelListError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw ModelListError.httpError(status: http?.statusCode ?? 0)
        }

        struct ModelsResponse: Decodable {
            let data: [ModelEntry]
        }
        struct ModelEntry: Decodable {
            let id: String
            let display_name: String?
        }

        do {
            let parsed = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return parsed.data.map { $0.id }.sorted()
        } catch {
            logger.error("Anthropic model list decode error: \(error.localizedDescription)")
            throw ModelListError.decodingError
        }
    }

    // MARK: Azure Anthropic

    /// Azure-hosted Anthropic: Azure doesn't expose a model-list endpoint for Anthropic models,
    /// so we return a curated set of known model IDs the user can pick from.
    private static func fetchAzureAnthropicModels(baseURL: String, apiKey: String) async throws
        -> [String]
    {
        // Azure's Anthropic integration doesn't provide a /v1/models endpoint.
        // Return well-known Claude models available on Azure AI Foundry.
        return [
            "claude-opus-4-6",
            "claude-sonnet-4-20250514",
            "claude-haiku-35-20241022",
        ]
    }

    // MARK: OpenAI-compatible

    /// OpenAI-compatible: GET /v1/models → { "data": [{ "id": "gpt-4o", ... }] }
    private static func fetchOpenAIModels(baseURL: String, apiKey: String) async throws -> [String]
    {
        guard let url = URL(string: "\(baseURL)/v1/models") else {
            throw ModelListError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw ModelListError.httpError(status: http?.statusCode ?? 0)
        }

        struct ModelsResponse: Decodable {
            let data: [ModelEntry]
        }
        struct ModelEntry: Decodable {
            let id: String
        }

        do {
            let parsed = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return parsed.data.map { $0.id }.sorted()
        } catch {
            logger.error("OpenAI model list decode error: \(error.localizedDescription)")
            throw ModelListError.decodingError
        }
    }

    // MARK: Errors

    enum ModelListError: LocalizedError {
        case noAPIKey
        case invalidURL
        case httpError(status: Int)
        case decodingError

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No API key set for this provider."
            case .invalidURL:
                return "Invalid provider URL."
            case .httpError(let s):
                return "HTTP \(s) error fetching models."
            case .decodingError:
                return "Could not parse model list."
            }
        }
    }
}

// MARK: - CharacterLLMConfig

/// Per-character LLM configuration, stored as `llm.json` in the character directory.
struct CharacterLLMConfig: Codable {
    var providerID: UUID?
    var modelID: String?
    var defaultFace: String?
    var defaultCodingFace: String?

    static let `default` = CharacterLLMConfig(
        providerID: nil, modelID: nil, defaultFace: nil, defaultCodingFace: nil)

    /// Load the config from the character's directory, falling back to `.default`.
    static func load(from directory: URL) -> CharacterLLMConfig {
        let url = directory.appendingPathComponent("llm.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CharacterLLMConfig.self, from: data)
        } catch {
            logger.warning(
                "Failed to load llm.json from \(directory.lastPathComponent): \(error.localizedDescription)"
            )
            return .default
        }
    }

    /// Persist the config to the character's directory as `llm.json`.
    func save(to directory: URL) {
        let url = directory.appendingPathComponent("llm.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else {
            logger.error("Failed to encode CharacterLLMConfig")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write llm.json: \(error.localizedDescription)")
        }
    }
}
