// CharacterDetailView.swift — aki-notch-ui

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CharacterDetailView: View {
    @ObservedObject var character: Character
    @ObservedObject var store: CharacterStore
    @ObservedObject var providerStore: ProviderStore
    var onAgentsChanged: () -> Void

    @State private var triggerConfig: CharacterTriggerConfig
    @State private var llmConfig: CharacterLLMConfig
    @State private var personalityText: String

    // Face import
    @State private var showFaceMoodPrompt = false
    @State private var pendingFaceData: Data?
    @State private var pendingFaceExtension = "png"
    @State private var faceMoodName = ""

    // Face rename
    @State private var showFaceRenamePrompt = false
    @State private var renamingFaceMood = ""
    @State private var faceNewName = ""

    // Memory
    @State private var newMemoryText = ""
    @State private var editingMemoryIndex: Int? = nil
    @State private var editingMemoryText = ""

    // Test
    @State private var testTriggerText: String = "you felt like saying something — test trigger"

    // Available models (fetched for the selected provider)
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false

    // Accent colour binding
    private var accentColorBinding: Binding<Color> {
        Binding<Color>(
            get: { Color(hex: character.accentHex) },
            set: { newColor in
                character.accentHex = newColor.hexString
                character.saveAccentHex()
            }
        )
    }

    init(
        character: Character, store: CharacterStore, providerStore: ProviderStore,
        onAgentsChanged: @escaping () -> Void
    ) {
        self._character = ObservedObject(wrappedValue: character)
        self._store = ObservedObject(wrappedValue: store)
        self._providerStore = ObservedObject(wrappedValue: providerStore)
        self.onAgentsChanged = onAgentsChanged
        self._triggerConfig = State(
            initialValue: CharacterTriggerConfig.load(from: character.directoryURL))
        self._llmConfig = State(
            initialValue: CharacterLLMConfig.load(from: character.directoryURL))
        self._personalityText = State(initialValue: character.personality)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identitySection
                llmSection
                defaultFacesSection
                personalitySection
                facesSection
                triggersSection
                conversationsSection
                testSection
                memoriesSection
            }
        }
        .onChange(of: character.id) { _, _ in
            triggerConfig = CharacterTriggerConfig.load(from: character.directoryURL)
            llmConfig = CharacterLLMConfig.load(from: character.directoryURL)
            personalityText = character.personality
            availableModels = []
        }
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        AgentSettingsSection(title: "IDENTITY — \(character.name.uppercased())") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Name")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(character.name)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.5)

                HStack {
                    Text("Accent Color")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(character.accentHex.uppercased())
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    ColorPicker("", selection: accentColorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 32)
                }

                Divider().opacity(0.5)

                HStack {
                    Text("Directory")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(character.directoryURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider().opacity(0.5)

                Button {
                    NSWorkspace.shared.open(character.directoryURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("Open Character Folder")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - LLM Section

    private var llmSection: some View {
        AgentSettingsSection(title: "LLM MODEL") {
            VStack(alignment: .leading, spacing: 12) {

                // Provider picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.system(size: 13, weight: .medium))

                    Picker(
                        "",
                        selection: Binding<String>(
                            get: { llmConfig.providerID?.uuidString ?? "__default__" },
                            set: { newVal in
                                llmConfig.providerID =
                                    (newVal == "__default__") ? nil : UUID(uuidString: newVal)
                                llmConfig.save(to: character.directoryURL)
                                availableModels = []
                                onAgentsChanged()
                            }
                        )
                    ) {
                        Text("Default (first available)").tag("__default__")
                        ForEach(providerStore.providers) { p in
                            Text(p.name).tag(p.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Divider().opacity(0.5)

                // Model — always a stable text field + optional picker from fetched list
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Model")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button {
                            fetchModelsForSelectedProvider()
                        } label: {
                            HStack(spacing: 3) {
                                if isFetchingModels {
                                    ProgressView().controlSize(.mini)
                                }
                                Text(isFetchingModels ? "Fetching…" : "Fetch Models")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isFetchingModels)
                    }

                    // Text field for manual entry (always present, stable layout)
                    TextField(
                        "claude-sonnet-4-20250514",
                        text: Binding<String>(
                            get: { llmConfig.modelID ?? "" },
                            set: { newVal in
                                llmConfig.modelID = newVal.isEmpty ? nil : newVal
                                llmConfig.save(to: character.directoryURL)
                                onAgentsChanged()
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                    // Quick-pick from fetched models (shown as clickable capsules)
                    if !availableModels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(availableModels, id: \.self) { model in
                                    Button {
                                        llmConfig.modelID = model
                                        llmConfig.save(to: character.directoryURL)
                                        onAgentsChanged()
                                    } label: {
                                        Text(model)
                                            .font(.system(size: 9, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background {
                                                Capsule().fill(
                                                    llmConfig.modelID == model
                                                        ? Color.accentColor.opacity(0.3)
                                                        : Color.secondary.opacity(0.15)
                                                )
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 30)
                    }

                    Text(
                        "Leave empty to use a default. Click \"Fetch Models\" to list available models from the provider."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Default Faces Section

    private var defaultFacesSection: some View {
        AgentSettingsSection(title: "DEFAULT FACES") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default Face")
                        .font(.system(size: 13, weight: .medium))
                    Picker(
                        "",
                        selection: Binding<String>(
                            get: { llmConfig.defaultFace ?? "" },
                            set: { newVal in
                                llmConfig.defaultFace = newVal.isEmpty ? nil : newVal
                                llmConfig.save(to: character.directoryURL)
                            }
                        )
                    ) {
                        Text("Auto (first alphabetically)").tag("")
                        ForEach(character.faceNames, id: \.self) { face in
                            Text(face).tag(face)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text("Used for fallback overlays and general interactions.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Coding Face")
                        .font(.system(size: 13, weight: .medium))
                    Picker(
                        "",
                        selection: Binding<String>(
                            get: { llmConfig.defaultCodingFace ?? "" },
                            set: { newVal in
                                llmConfig.defaultCodingFace = newVal.isEmpty ? nil : newVal
                                llmConfig.save(to: character.directoryURL)
                            }
                        )
                    ) {
                        Text("Same as default face").tag("")
                        ForEach(character.faceNames, id: \.self) { face in
                            Text(face).tag(face)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text("Used when asking to run CLI commands.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fetchModelsForSelectedProvider() {
        let provider: LLMProvider?
        if let providerID = llmConfig.providerID {
            provider = providerStore.provider(withID: providerID)
        } else {
            provider = providerStore.providers.first
        }
        guard let provider = provider else { return }

        isFetchingModels = true
        Task {
            do {
                let models = try await ModelListService.fetchModels(provider: provider)
                await MainActor.run {
                    availableModels = models
                    isFetchingModels = false
                }
            } catch {
                await MainActor.run {
                    availableModels = []
                    isFetchingModels = false
                }
            }
        }
    }

    // MARK: - Personality Section

    private var personalitySection: some View {
        AgentSettingsSection(title: "PERSONALITY") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $personalityText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 300)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(0.15))
                    }
                    .onChange(of: personalityText) { _, newValue in
                        character.personality = newValue
                    }
                    .accessibilityLabel("Personality prompt")
                    .accessibilityHint("Edit the personality prompt sent to the LLM")

                HStack {
                    Spacer()
                    Button("Save") {
                        character.personality = personalityText
                        character.savePersonality()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("The personality prompt sent to the LLM. Saved to personality.md.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Faces Section

    private let faceGridColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var facesSection: some View {
        AgentSettingsSection(title: "FACES") {
            VStack(alignment: .leading, spacing: 12) {
                if character.faces.isEmpty {
                    Text("No faces imported yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    LazyVGrid(columns: faceGridColumns, spacing: 12) {
                        ForEach(character.faceNames, id: \.self) { mood in
                            faceCell(mood: mood)
                        }
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Button {
                        importFaceFromDisk()
                    } label: {
                        Label("Import Faces", systemImage: "photo.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        importFacesFromFolder()
                    } label: {
                        Label("Import Folder", systemImage: "folder.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Text("PNG, JPEG, GIF, WebP")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            // Import mood name prompt
            .alert("Face Mood Name", isPresented: $showFaceMoodPrompt) {
                TextField("e.g. happy, angry, thinking", text: $faceMoodName)
                Button("Import") {
                    let mood = faceMoodName.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !mood.isEmpty, let data = pendingFaceData else { return }
                    store.importFace(
                        for: character, named: mood, imageData: data,
                        fileExtension: pendingFaceExtension)
                    pendingFaceData = nil
                    pendingFaceExtension = "png"
                    faceMoodName = ""
                }
                Button("Cancel", role: .cancel) {
                    pendingFaceData = nil
                    pendingFaceExtension = "png"
                    faceMoodName = ""
                }
            } message: {
                Text("Enter the mood/emotion name for this face image.")
            }
            // Rename mood prompt
            .alert("Rename Face", isPresented: $showFaceRenamePrompt) {
                TextField("New mood name", text: $faceNewName)
                Button("Rename") {
                    let newMood = faceNewName.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !newMood.isEmpty, newMood != renamingFaceMood else { return }
                    renameFace(from: renamingFaceMood, to: newMood)
                    renamingFaceMood = ""
                    faceNewName = ""
                }
                Button("Cancel", role: .cancel) {
                    renamingFaceMood = ""
                    faceNewName = ""
                }
            } message: {
                Text("Enter a new mood name for \"\(renamingFaceMood)\".")
            }
        }
    }

    private func faceCell(mood: String) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let data = character.faces[mood] {
                    if isAnimatedImageData(data) {
                        AnimatedImageView(data: data)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityLabel("Face: \(mood) (animated)")
                    } else if let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityLabel("Face: \(mood)")
                    }
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Image(systemName: "face.dashed")
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityLabel("Face: \(mood), no image")
                }

                // Delete button
                Button {
                    store.deleteFace(for: character, named: mood)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel("Delete \(mood) face")
                .accessibilityHint("Double-tap to remove this face image")
            }

            // Clickable mood label — click to rename
            Button {
                renamingFaceMood = mood
                faceNewName = mood
                showFaceRenamePrompt = true
            } label: {
                HStack(spacing: 2) {
                    Text(mood)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Click to rename this mood")
            .accessibilityLabel("Rename \(mood) face")
            .accessibilityHint("Double-tap to rename this mood")
        }
        .accessibilityElement(children: .contain)
    }

    private func importFaceFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "Choose face image(s)"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        if urls.count == 1 {
            // Single file: prompt for mood name (existing behavior)
            guard let data = try? Data(contentsOf: urls[0]) else {
                print("[AgentSettings] Failed to read image data from \(urls[0].path)")
                return
            }
            pendingFaceData = data
            pendingFaceExtension = urls[0].pathExtension.lowercased()
            faceMoodName = urls[0].deletingPathExtension().lastPathComponent.lowercased()
            showFaceMoodPrompt = true
        } else {
            // Multiple files: batch import using filenames as mood names
            for url in urls {
                guard let data = try? Data(contentsOf: url) else {
                    print("[AgentSettings] Failed to read image data from \(url.path)")
                    continue
                }
                let mood = url.deletingPathExtension().lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                store.importFace(for: character, named: mood, imageData: data, fileExtension: ext)
            }
        }
    }

    private func importFacesFromFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder of face images"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let fm = FileManager.default
        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
        var imported = 0

        guard
            let contents = try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return }

        for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }

            let mood = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            store.importFace(for: character, named: mood, imageData: data, fileExtension: ext)
            imported += 1
        }

        if imported > 0 {
            print("[AgentSettings] Batch imported \(imported) face(s) from folder")
        }
    }

    private func renameFace(from oldMood: String, to newMood: String) {
        // Get the image data
        guard let imageData = character.faces[oldMood] else { return }

        // Detect the file extension from the existing file on disk
        let facesDir = character.directoryURL.appendingPathComponent("faces", isDirectory: true)
        let supportedExts = ["png", "jpg", "jpeg", "webp", "gif"]
        var ext = "png"
        for e in supportedExts {
            let url = facesDir.appendingPathComponent("\(oldMood.lowercased()).\(e)")
            if FileManager.default.fileExists(atPath: url.path) {
                ext = e
                break
            }
        }

        // Remove old face, import new one with same extension
        store.deleteFace(for: character, named: oldMood)
        store.importFace(for: character, named: newMood, imageData: imageData, fileExtension: ext)
    }

    // MARK: - Memories Section

    private var memoriesSection: some View {
        AgentSettingsSection(title: "MEMORIES") {
            VStack(alignment: .leading, spacing: 10) {
                // Add memory input at the top
                HStack(spacing: 8) {
                    TextField("New memory...", text: $newMemoryText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { addMemory() }

                    Button("Add") { addMemory() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Divider().opacity(0.5)

                let lines = character.memoryLines

                if lines.isEmpty {
                    Text("No memories recorded yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(lines.enumerated()).reversed(), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, alignment: .trailing)

                            if editingMemoryIndex == index {
                                TextField("Memory…", text: $editingMemoryText, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .lineLimit(1...5)
                                    .onSubmit { saveEditingMemory() }

                                Button {
                                    saveEditingMemory()
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.green)
                                }
                                .buttonStyle(.plain)
                                .help("Save")

                                Button {
                                    editingMemoryIndex = nil
                                    editingMemoryText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Cancel")
                            } else {
                                Text(line)
                                    .font(.system(size: 12))
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        editingMemoryIndex = index
                                        editingMemoryText = line
                                    }
                                    .help("Click to edit")

                                Button {
                                    _ = character.deleteMemory(index + 1)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .help("Delete memory #\(index + 1)")
                            }
                        }
                        .padding(.vertical, 3)

                        if index > 0 {
                            Divider().opacity(0.3)
                        }
                    }
                }

                Text("\(lines.count) memory line(s) stored in memories.md")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func saveEditingMemory() {
        guard let index = editingMemoryIndex else { return }
        let content = editingMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        _ = character.editMemory(index + 1, content)
        editingMemoryIndex = nil
        editingMemoryText = ""
    }

    private func addMemory() {
        let content = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        character.appendMemory(content)
        newMemoryText = ""
        // objectWillChange is already sent by appendMemory after the disk write
    }

    // MARK: - Triggers Section

    private var triggersSection: some View {
        AgentSettingsSection(title: "TRIGGERS") {
            VStack(alignment: .leading, spacing: 14) {

                // Per-character activation
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $triggerConfig.enabled) {
                        Text("Character active")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .onChange(of: triggerConfig.enabled) { _, _ in
                        saveTriggerConfig()
                        onAgentsChanged()
                    }

                    Text(
                        "When active, this character's triggers will fire and it can respond to compose messages."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.5)

                // Startup greeting
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $triggerConfig.startupGreeting) {
                        Text("Startup greeting")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .toggleStyle(.switch)

                    Text(
                        "When enabled, this character sends an LLM-generated greeting at launch — replacing the static startup card from Overlay settings."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                    if triggerConfig.startupGreeting {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Delay")
                                    .font(.system(size: 12))
                                Spacer()
                                Text("\(Int(triggerConfig.startupGreetingDelay))s")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            Slider(value: $triggerConfig.startupGreetingDelay, in: 0...300, step: 1)
                        }
                        .padding(.leading, 20)
                    }
                }

                Divider().opacity(0.5)

                // Trigger list
                Text("Trigger Rules")
                    .font(.system(size: 13, weight: .medium))

                if triggerConfig.triggers.isEmpty {
                    Text("No triggers configured. Add a random or scheduled trigger below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach($triggerConfig.triggers) { $trigger in
                        triggerRow(trigger: $trigger)
                    }
                }

                // Add trigger buttons
                HStack(spacing: 8) {
                    Button {
                        triggerConfig.triggers.append(TriggerConfig(type: .random))
                    } label: {
                        Label("Random", systemImage: "dice")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        triggerConfig.triggers.append(TriggerConfig(type: .scheduled))
                    } label: {
                        Label("Scheduled", systemImage: "clock")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }

                Divider().opacity(0.5)

                HStack {
                    Spacer()
                    Button("Save Triggers") {
                        saveTriggerConfig()
                        onAgentsChanged()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .onChange(of: triggerConfig.startupGreeting) { _, _ in saveTriggerConfig() }
            .onChange(of: triggerConfig.startupGreetingDelay) { _, _ in saveTriggerConfig() }
        }
    }

    private func triggerRow(trigger: Binding<TriggerConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let isRandom = trigger.wrappedValue.type == .random
                Label(
                    isRandom ? "Random" : "Scheduled",
                    systemImage: isRandom ? "dice" : "clock"
                )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    Capsule()
                        .fill(isRandom ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                }

                Spacer()

                Button {
                    triggerConfig.triggers.removeAll { $0.id == trigger.wrappedValue.id }
                    saveTriggerConfig()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            if trigger.wrappedValue.type == .random {
                randomTriggerControls(trigger: trigger)
            } else {
                scheduledTriggerControls(trigger: trigger)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.1))
        }
    }

    private func randomTriggerControls(trigger: Binding<TriggerConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min interval")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(trigger.wrappedValue.minIntervalMinutes)) min")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Slider(value: trigger.minIntervalMinutes, in: 5...360, step: 5)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max interval")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(trigger.wrappedValue.maxIntervalMinutes)) min")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Slider(value: trigger.maxIntervalMinutes, in: 5...360, step: 5)
            }
        }
    }

    private func scheduledTriggerControls(trigger: Binding<TriggerConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if trigger.wrappedValue.schedule.isEmpty {
                Text("No schedule entries. Add a time below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(trigger.schedule) { $entry in
                    HStack(spacing: 8) {
                        TextField("HH:mm", text: $entry.time)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 64)

                        TextField("Context (e.g. morning greeting)", text: $entry.context)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))

                        Button {
                            trigger.wrappedValue.schedule.removeAll { $0.id == entry.id }
                            saveTriggerConfig()
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                trigger.wrappedValue.schedule.append(ScheduleEntry())
            } label: {
                Label("Add Time", systemImage: "plus.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private func saveTriggerConfig() {
        triggerConfig.save(to: character.directoryURL)
        // Defer objectWillChange to the next run-loop iteration so it does
        // not collide with the @State update that is still in flight.
        // Without this, SwiftUI can drop the @State visual refresh.
        let char = character
        DispatchQueue.main.async {
            char.objectWillChange.send()
        }
    }

    // MARK: - Test Section

    // MARK: - Conversations Section

    private var conversationsSection: some View {
        AgentSettingsSection(title: "CONVERSATIONS") {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Multi-character conversations let two or more characters talk to each other — and optionally pull the user in."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                if triggerConfig.conversations.isEmpty {
                    Text("No conversations configured. Add one below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach($triggerConfig.conversations) { $convo in
                        conversationRow(convo: $convo)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        triggerConfig.conversations.append(
                            ConversationConfig(
                                participantNames: [character.name]
                            ))
                    } label: {
                        Label("Add Conversation", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }

                Divider().opacity(0.5)

                HStack {
                    Spacer()
                    Button("Save Conversations") {
                        saveTriggerConfig()
                        onAgentsChanged()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private func conversationRow(convo: Binding<ConversationConfig>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    "Conversation",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    Capsule()
                        .fill(Color.purple.opacity(0.2))
                }

                Spacer()

                Button {
                    triggerConfig.conversations.removeAll { $0.id == convo.wrappedValue.id }
                    saveTriggerConfig()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            // Participants
            VStack(alignment: .leading, spacing: 6) {
                Text("Participants")
                    .font(.system(size: 12, weight: .medium))

                if convo.wrappedValue.participantNames.isEmpty {
                    Text("Add at least 2 characters.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(convo.wrappedValue.participantNames.enumerated()), id: \.offset) {
                        index, name in
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(.blue.opacity(0.15))
                                }

                            Spacer()

                            Button {
                                convo.wrappedValue.participantNames.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Add participant picker — shows characters not yet in the list
                let available = store.characters.filter { char in
                    !convo.wrappedValue.participantNames.contains(char.name)
                }
                if !available.isEmpty {
                    Menu {
                        ForEach(available) { char in
                            Button(char.name) {
                                convo.wrappedValue.participantNames.append(char.name)
                            }
                        }
                    } label: {
                        Label("Add Participant", systemImage: "plus.circle")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Divider().opacity(0.3)

            // Context template
            VStack(alignment: .leading, spacing: 4) {
                Text("Context / Topic")
                    .font(.system(size: 12, weight: .medium))
                TextField("e.g. Discuss the user's recent work…", text: convo.contextTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("Context string sent to both characters as the conversation topic.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Divider().opacity(0.3)

            // Timing controls
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max turns")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(convo.wrappedValue.maxTurns)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(convo.wrappedValue.maxTurns) },
                            set: { convo.wrappedValue.maxTurns = Int($0) }
                        ),
                        in: 2...20,
                        step: 1
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Pause between turns")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(String(format: "%.1f", convo.wrappedValue.pauseBetweenTurns))s")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    Slider(value: convo.pauseBetweenTurns, in: 0.5...5.0, step: 0.5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min interval")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(Int(convo.wrappedValue.minIntervalMinutes)) min")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Slider(value: convo.minIntervalMinutes, in: 5...360, step: 5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max interval")
                            .font(.system(size: 12))
                        Spacer()
                        Text("\(Int(convo.wrappedValue.maxIntervalMinutes)) min")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    Slider(value: convo.maxIntervalMinutes, in: 5...360, step: 5)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.black.opacity(0.1))
        }
    }

    private var testSection: some View {
        AgentSettingsSection(title: "TEST CHARACTER") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fire a test trigger to see how this character responds.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Trigger text")
                        .font(.system(size: 12, weight: .medium))
                    TextField("Trigger context…", text: $testTriggerText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("This is the context string sent to the LLM as [SYSTEM TRIGGER: …].")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Button {
                        fireTestTrigger()
                    } label: {
                        Label("Test Now", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        testTriggerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    // Test conversation — needs at least one other character
                    let others = store.characters.filter { $0.id != character.id }
                    if !others.isEmpty {
                        Button {
                            fireTestConversation()
                        } label: {
                            Label("Test Conversation", systemImage: "bubble.left.and.bubble.right")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if store.characters.count >= 2 {
                    Text(
                        "Test Conversation starts a quick chat between this character and the next available one."
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fireTestTrigger() {
        let text = testTriggerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Post a notification that AppDelegate can pick up
        NotificationCenter.default.post(
            name: .testCharacterTrigger,
            object: nil,
            userInfo: ["character": character, "context": text]
        )
    }

    private func fireTestConversation() {
        // Pick the first other character as the conversation partner
        guard let partner = store.characters.first(where: { $0.id != character.id }) else { return }

        NotificationCenter.default.post(
            name: .testConversationTrigger,
            object: nil,
            userInfo: [
                "participants": [character, partner],
                "context": "You just bumped into each other — have a quick, fun chat!",
                "maxTurns": 4,
                "pauseBetweenTurns": 1.0,
            ]
        )
    }
}
