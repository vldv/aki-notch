//
//  AgentSettingsView.swift
//  aki-notch-ui
//
//  Settings view for managing characters, LLM providers, faces, memories,
//  triggers, and per-character model configuration.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main Settings View

struct AgentSettingsView: View {
    @ObservedObject var store: CharacterStore
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var settings: OverlaySettings
    var onAgentsChanged: () -> Void = {}

    // Character selection
    @State private var selectedCharacterID: String?

    // New character creation
    @State private var showNewCharacterSheet = false
    @State private var newCharacterName = ""

    // Delete confirmation
    @State private var showDeleteConfirmation = false

    private var selectedCharacter: Character? {
        guard let id = selectedCharacterID else { return nil }
        return store.characters.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Characters ───────────────────────────
                characterListSection

                // ── Character Detail (shown below the list when one is selected) ──
                if let character = selectedCharacter {
                    CharacterDetailView(
                        character: character,
                        store: store,
                        providerStore: providerStore,
                        onAgentsChanged: onAgentsChanged
                    )
                    .id(character.id)
                    .transition(.opacity)
                }
            }
            .padding(24)
            .animation(.easeInOut(duration: 0.2), value: selectedCharacterID)
        }
    }

    // MARK: - Character List Section

    private var characterListSection: some View {
        AgentSettingsSection(title: "CHARACTERS") {
            VStack(alignment: .leading, spacing: 10) {
                if store.characters.isEmpty {
                    Text("No characters yet. Click + to create one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.characters) { character in
                        CharacterRowView(
                            character: character,
                            isSelected: selectedCharacterID == character.id,
                            onSelect: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedCharacterID =
                                        (selectedCharacterID == character.id)
                                        ? nil : character.id
                                }
                            },
                            onAgentsChanged: onAgentsChanged
                        )
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Button {
                        newCharacterName = ""
                        showNewCharacterSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .help("Create new character")

                    Button {
                        if selectedCharacter != nil {
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedCharacter == nil)
                    .help("Delete selected character")

                    Spacer()

                    Text("\(store.characters.count) character(s)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .alert("New Character", isPresented: $showNewCharacterSheet) {
                TextField("Character name", text: $newCharacterName)
                Button("Create") {
                    let name = newCharacterName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    if let created = store.createCharacter(name: name) {
                        selectedCharacterID = created.id
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for the new character.")
            }
            .alert("Delete Character", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let character = selectedCharacter {
                        store.deleteCharacter(character)
                        selectedCharacterID = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let character = selectedCharacter {
                    Text(
                        "Are you sure you want to delete \"\(character.name)\"? This cannot be undone."
                    )
                }
            }
        }
    }

}

// MARK: - Character Row View

private struct CharacterRowView: View {
    @ObservedObject var character: Character
    let isSelected: Bool
    let onSelect: () -> Void
    var onAgentsChanged: () -> Void

    @State private var isEnabled = true

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()

            Button {
                onSelect()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: character.accentHex))
                        .frame(width: 10, height: 10)

                    Text(character.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(character.faceNames.count) faces")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.1) : Color.black.opacity(0.1))
        }
        .onAppear { reloadEnabled() }
        .onReceive(character.objectWillChange) { _ in reloadEnabled() }
        .onChange(of: isEnabled) { _, newValue in
            var config = CharacterTriggerConfig.load(from: character.directoryURL)
            guard config.enabled != newValue else { return }
            config.enabled = newValue
            config.save(to: character.directoryURL)
            onAgentsChanged()
        }
    }

    private func reloadEnabled() {
        let config = CharacterTriggerConfig.load(from: character.directoryURL)
        if isEnabled != config.enabled {
            isEnabled = config.enabled
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let testCharacterTrigger = Notification.Name("testCharacterTrigger")
    static let testConversationTrigger = Notification.Name("testConversationTrigger")
}

// MARK: - Section Helper

struct AgentSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.secondary)

            content
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct AgentSettingsView_Previews: PreviewProvider {
        static var previews: some View {
            AgentSettingsView(
                store: CharacterStore(),
                providerStore: ProviderStore(),
                settings: OverlaySettings()
            )
            .frame(width: 480, height: 800)
        }
    }
#endif
