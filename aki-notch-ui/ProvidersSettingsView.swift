// ProvidersSettingsView.swift — aki-notch-ui

import SwiftUI

// MARK: - Providers Settings View (standalone tab)

struct ProvidersSettingsView: View {
    @ObservedObject var providerStore: ProviderStore
    var onAgentsChanged: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AgentSettingsSection(title: "LLM PROVIDERS") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(
                            "Configure API providers that your characters can use. Each character picks a provider and model in its own settings."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                        if providerStore.providers.isEmpty {
                            Text("No providers configured yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(providerStore.providers) { provider in
                                ProviderRow(
                                    provider: provider, providerStore: providerStore,
                                    onAgentsChanged: onAgentsChanged)
                            }
                        }

                        Divider().opacity(0.5)

                        HStack(spacing: 8) {
                            Button {
                                let _ = providerStore.addProvider(
                                    name: "New Provider",
                                    baseURL: "https://api.anthropic.com",
                                    type: .anthropic
                                )
                            } label: {
                                Label("Add Provider", systemImage: "plus.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()

                            Text("\(providerStore.providers.count) provider(s)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Provider Row

private struct ProviderRow: View {
    @ObservedObject var provider: LLMProvider
    @ObservedObject var providerStore: ProviderStore
    var onAgentsChanged: () -> Void

    @State private var apiKey: String = ""
    @State private var isExpanded = false
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var fetchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — click anywhere to expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // Status indicator (matches character row's colored dot position)
                    if provider.apiKey != nil && !(provider.apiKey ?? "").isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }

                    Image(
                        systemName: {
                            switch provider.providerType {
                            case .anthropic: return "brain.head.profile"
                            case .azureAnthropic: return "cloud.fill"
                            case .openAICompatible: return "server.rack"
                            }
                        }()
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    Text(provider.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(
                        {
                            switch provider.providerType {
                            case .anthropic: return "Anthropic"
                            case .azureAnthropic: return "Azure Anthropic"
                            case .openAICompatible: return "OpenAI"
                            }
                        }()
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isExpanded
                        ? Color.accentColor.opacity(0.1) : Color.black.opacity(0.1))
        }
        .onAppear {
            apiKey = provider.apiKey ?? ""
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5).padding(.top, 8)

            // Name
            HStack {
                Text("Name")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 70, alignment: .leading)
                TextField("Provider name", text: $provider.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onChange(of: provider.name) { _, _ in providerStore.save() }
            }

            // Type
            HStack {
                Text("Type")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 70, alignment: .leading)
                Picker("", selection: $provider.providerType) {
                    Text("Anthropic").tag(LLMProvider.ProviderType.anthropic)
                    Text("Azure Anthropic").tag(LLMProvider.ProviderType.azureAnthropic)
                    Text("OpenAI-compat").tag(LLMProvider.ProviderType.openAICompatible)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: provider.providerType) { _, newType in
                    // Update base URL placeholder when switching types
                    if provider.apiBaseURL.isEmpty
                        || provider.apiBaseURL == "https://api.anthropic.com"
                        || provider.apiBaseURL.hasSuffix(".openai.azure.com/anthropic")
                    {
                        switch newType {
                        case .anthropic:
                            provider.apiBaseURL = "https://api.anthropic.com"
                        case .azureAnthropic:
                            provider.apiBaseURL = "https://<resource>.openai.azure.com/anthropic"
                        case .openAICompatible:
                            provider.apiBaseURL = ""
                        }
                    }
                    providerStore.save()
                    availableModels = []
                }
            }

            // Base URL
            HStack {
                Text("Base URL")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 70, alignment: .leading)
                TextField(
                    {
                        switch provider.providerType {
                        case .anthropic: return "https://api.anthropic.com"
                        case .azureAnthropic: return "https://<resource>.openai.azure.com/anthropic"
                        case .openAICompatible: return "http://localhost:11434"
                        }
                    }(),
                    text: $provider.apiBaseURL
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onChange(of: provider.apiBaseURL) { _, _ in
                    providerStore.save()
                    availableModels = []
                }
            }

            // API Key
            HStack(spacing: 8) {
                Text("API Key")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 70, alignment: .leading)
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onChange(of: apiKey) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            provider.setApiKey(trimmed)
                        } else {
                            provider.deleteApiKey()
                        }
                        onAgentsChanged()
                    }
            }

            Text("Stored securely in the macOS Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            // Fetch models button
            HStack(spacing: 8) {
                Button {
                    fetchModels()
                } label: {
                    HStack(spacing: 4) {
                        if isFetchingModels {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(isFetchingModels ? "Fetching…" : "Fetch Models")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFetchingModels || apiKey.isEmpty)

                if !availableModels.isEmpty {
                    Text("\(availableModels.count) model(s)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let error = fetchError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Spacer()

                // Delete provider
                Button(role: .destructive) {
                    providerStore.deleteProvider(provider)
                    onAgentsChanged()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
                .help("Delete this provider")
            }

            // Show available models if fetched
            if !availableModels.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Available models:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model)
                                    .font(.system(size: 9, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background {
                                        Capsule().fill(.quaternary)
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 50)
                }
            }
        }
    }

    private func fetchModels() {
        isFetchingModels = true
        fetchError = nil
        Task {
            do {
                let models = try await ModelListService.fetchModels(provider: provider)
                await MainActor.run {
                    availableModels = models
                    isFetchingModels = false
                }
            } catch {
                await MainActor.run {
                    fetchError = error.localizedDescription
                    isFetchingModels = false
                }
            }
        }
    }
}
