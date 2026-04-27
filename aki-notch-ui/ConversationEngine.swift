//
//  ConversationEngine.swift
//  aki-notch-ui
//
//  Manages multi-character conversations where two or more AI agent
//  characters talk to each other, and optionally pull the user in.
//  Refactored to use LLMClient / AgentTool / AgentLoop abstractions.
//

import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "ConversationEngine")

// MARK: - Conversation Transcript Entry

/// A single entry in the conversation transcript.
struct ConversationTranscriptEntry {
    let speaker: String  // character name or "User"
    let message: String
    let face: String?  // nil for user messages
}

// MARK: - Conversation Config

/// Codable configuration for a multi-character conversation, suitable for
/// persistence in triggers.json or similar.
struct ConversationConfig: Codable, Identifiable {
    let id: UUID
    var participantNames: [String]  // character names
    var contextTemplate: String  // topic/context for the conversation
    var maxTurns: Int  // max turns before auto-ending
    var pauseBetweenTurns: Double  // seconds between turns (default 1.0)
    var minIntervalMinutes: Double  // min random interval between fires
    var maxIntervalMinutes: Double  // max random interval between fires

    init(
        participantNames: [String] = [],
        contextTemplate: String = "",
        maxTurns: Int = 6,
        pauseBetweenTurns: Double = 1.0,
        minIntervalMinutes: Double = 60,
        maxIntervalMinutes: Double = 240
    ) {
        self.id = UUID()
        self.participantNames = participantNames
        self.contextTemplate = contextTemplate
        self.maxTurns = maxTurns
        self.pauseBetweenTurns = pauseBetweenTurns
        self.minIntervalMinutes = minIntervalMinutes
        self.maxIntervalMinutes = maxIntervalMinutes
    }
}

// MARK: - Conversation Action

/// Action returned by tool execution to control the conversation flow.
private enum ConversationAction {
    case continueConversation
    case endConversation
}

// MARK: - TranscriptRef

/// Shared mutable reference for the conversation transcript.
/// Captured by tool classes so they can append entries during execution.
class TranscriptRef: @unchecked Sendable {
    var entries: [ConversationTranscriptEntry] = []
}

// MARK: - Conversation Tool Implementations

// MARK: ConversationReplyToTool

/// Sends a message in the conversation, showing it as an overlay card.
final class ConversationReplyToTool: AgentTool, @unchecked Sendable {
    let name = "reply_to"
    let description =
        "Send a message in the conversation. This shows your message as an overlay to the user."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "message": LLMPropertySchema(
                type: "string",
                description: "The message to send in the conversation."
            ),
            "face": LLMPropertySchema(
                type: "string",
                description:
                    "The face/emotion to show. Must be one of the available faces."
            ),
        ],
        required: ["face", "message"]
    )
    let executionMode: ToolExecutionMode = .sequential

    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings
    private let character: Character
    private let participantIndex: Int
    private let participantCount: Int
    private let transcriptRef: TranscriptRef

    init(
        viewModel: NotchOverlayViewModel,
        panelController: NotchPanelController,
        settings: OverlaySettings,
        character: Character,
        participantIndex: Int,
        participantCount: Int,
        transcriptRef: TranscriptRef
    ) {
        self.viewModel = viewModel
        self.panelController = panelController
        self.settings = settings
        self.character = character
        self.participantIndex = participantIndex
        self.participantCount = participantCount
        self.transcriptRef = transcriptRef
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard let message = arguments["message"]?.stringValue,
            let face = arguments["face"]?.stringValue
        else {
            return .error("Error: missing required parameters 'message' and 'face'.")
        }

        // Collapse the previous card first so the new one gets a fresh
        // drop-down animation (otherwise SwiftUI reuses the expanded view).
        await MainActor.run {
            if viewModel.isExpanded {
                viewModel.collapseCard()
            }
        }
        try? await Task.sleep(for: .milliseconds(500))

        let request = OverlayAPIRequest(
            title: nil,
            name: character.name,
            nameColor: character.accentHex,
            message: message,
            imageURL: nil,
            imageBase64: character.getFaceBase64(face),
            accentHex: character.accentHex,
            expanded: true
        )

        // Position the portrait: for 2-char convos, 0.33 and 0.66;
        // for 1 or non-conversation, centered at 0.5.
        let imagePos: CGFloat
        if participantCount >= 2 {
            imagePos = CGFloat(participantIndex + 1) / CGFloat(participantCount + 1)
        } else {
            imagePos = 0.5
        }

        await MainActor.run {
            viewModel.apply(
                request, appearanceDuration: settings.appearanceDuration,
                imagePosition: imagePos)
            panelController.show()
        }

        // Append to shared transcript.
        transcriptRef.entries.append(
            ConversationTranscriptEntry(
                speaker: character.name,
                message: message,
                face: face
            )
        )

        // Record in history.
        HistoryStore.shared.recordCharacterMessage(
            characterName: character.name,
            accentColorHex: character.accentHex,
            message: message,
            faceName: face
        )

        // Wait for typewriter to finish, with a safety timeout.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor in
                        self.viewModel.overlaySequenceContinuation = continuation
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))  // Safety timeout
            }
            // First one to finish wins
            await group.next()
            group.cancelAll()
        }

        // Brief post-display pause so the user can read the completed message.
        try? await Task.sleep(for: .seconds(1.5))

        return .success("Message sent.")
    }
}

// MARK: ConversationEndTool

/// End the conversation, optionally showing a final message.
final class ConversationEndTool: AgentTool, @unchecked Sendable {
    let name = "end_conversation"
    let description =
        "End the conversation. Optionally send a final message before closing."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "message": LLMPropertySchema(
                type: "string",
                description:
                    "Optional final message to display before ending."
            ),
            "face": LLMPropertySchema(
                type: "string",
                description:
                    "Face/emotion for the final message."
            ),
        ],
        required: []
    )
    let executionMode: ToolExecutionMode = .sequential

    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings
    private let character: Character
    private let participantIndex: Int
    private let participantCount: Int
    private let transcriptRef: TranscriptRef

    init(
        viewModel: NotchOverlayViewModel,
        panelController: NotchPanelController,
        settings: OverlaySettings,
        character: Character,
        participantIndex: Int,
        participantCount: Int,
        transcriptRef: TranscriptRef
    ) {
        self.viewModel = viewModel
        self.panelController = panelController
        self.settings = settings
        self.character = character
        self.participantIndex = participantIndex
        self.participantCount = participantCount
        self.transcriptRef = transcriptRef
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        let message = arguments["message"]?.stringValue
        let face = arguments["face"]?.stringValue

        // If there's a final message, show it as an overlay.
        if let message = message, !message.isEmpty {
            let faceBase64: String?
            if let face = face {
                faceBase64 = character.getFaceBase64(face)
            } else {
                faceBase64 = nil
            }

            let request = OverlayAPIRequest(
                title: nil,
                name: character.name,
                nameColor: character.accentHex,
                message: message,
                imageURL: nil,
                imageBase64: faceBase64,
                accentHex: character.accentHex,
                expanded: true
            )

            let imagePos: CGFloat
            if participantCount >= 2 {
                imagePos =
                    CGFloat(participantIndex + 1) / CGFloat(participantCount + 1)
            } else {
                imagePos = 0.5
            }

            await MainActor.run {
                viewModel.apply(
                    request, appearanceDuration: settings.appearanceDuration,
                    imagePosition: imagePos)
                panelController.show()
            }

            // Append the final message to the transcript.
            transcriptRef.entries.append(
                ConversationTranscriptEntry(
                    speaker: character.name,
                    message: message,
                    face: face
                )
            )

            HistoryStore.shared.recordCharacterMessage(
                characterName: character.name,
                accentColorHex: character.accentHex,
                message: message,
                faceName: face
            )

            // Wait for typewriter to finish, with a safety timeout.
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withCheckedContinuation {
                        (continuation: CheckedContinuation<Void, Never>) in
                        Task { @MainActor in
                            self.viewModel.overlaySequenceContinuation = continuation
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))  // Safety timeout
                }
                // First one to finish wins
                await group.next()
                group.cancelAll()
            }

            // Brief post-display pause so the user can read the completed message.
            try? await Task.sleep(for: .seconds(1.5))
        }

        return .terminate("Conversation ended.")
    }
}

// MARK: ConversationStartGameTool

/// Start a mini-game during a conversation.
final class ConversationStartGameTool: AgentTool, @unchecked Sendable {
    let name = "start_game"
    let description =
        "Start a mini-game with the user during the conversation. The game runs in the notch overlay. You will receive the result when the game ends."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "game": LLMPropertySchema(
                type: "string",
                description: "Which game to play. One of: tic_tac_toe, snake, hangman."
            ),
            "face": LLMPropertySchema(
                type: "string",
                description: "The face/emotion to show during the game."
            ),
            "hangman_mode": LLMPropertySchema(
                type: "string",
                description: "For hangman: 'user_guesses' or 'agent_guesses'."
            ),
            "hangman_word": LLMPropertySchema(
                type: "string",
                description:
                    "For hangman user_guesses: the word for the user to guess."
            ),
        ],
        required: ["game", "face"]
    )
    let executionMode: ToolExecutionMode = .sequential

    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings
    private let character: Character
    private let gameViewModel: GameViewModel?

    init(
        viewModel: NotchOverlayViewModel,
        panelController: NotchPanelController,
        settings: OverlaySettings,
        character: Character,
        gameViewModel: GameViewModel?
    ) {
        self.viewModel = viewModel
        self.panelController = panelController
        self.settings = settings
        self.character = character
        self.gameViewModel = gameViewModel
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard let gameStr = arguments["game"]?.stringValue,
            let face = arguments["face"]?.stringValue
        else {
            return .error("Error: missing required parameters 'game' and 'face'.")
        }

        guard let gameType = GameType(rawValue: gameStr) else {
            return .error("Error: unknown game '\(gameStr)'.")
        }

        guard let gameVM = gameViewModel else {
            return .error("Error: game system not available.")
        }

        let faceData = character.getFaceBase64(face).flatMap {
            Data(base64Encoded: $0)
        }

        let result: GameResult = await withCheckedContinuation { continuation in
            Task { @MainActor in
                gameVM.settings = self.settings
                gameVM.completionHandler = { result in
                    continuation.resume(returning: result)
                }

                switch gameType {
                case .ticTacToe:
                    gameVM.startTicTacToe(
                        characterName: self.character.name,
                        accentHex: self.character.accentHex,
                        faceData: faceData
                    )
                case .snake:
                    gameVM.startSnake(
                        characterName: self.character.name,
                        accentHex: self.character.accentHex,
                        faceData: faceData
                    )
                case .hangman:
                    let modeStr =
                        arguments["hangman_mode"]?.stringValue ?? "user_guesses"
                    let mode = HangmanMode(rawValue: modeStr) ?? .userGuesses
                    let word = arguments["hangman_word"]?.stringValue ?? ""
                    gameVM.startHangman(
                        word: word,
                        mode: mode,
                        characterName: self.character.name,
                        accentHex: self.character.accentHex,
                        faceData: faceData
                    )
                }

                self.viewModel.startGame(gameVM: gameVM)
                self.panelController.show()
                self.panelController.enableInteraction(
                    smallMode: self.settings.smallMode,
                    contentHeight: self.viewModel.interactiveCardHeight
                )
            }
        }

        await MainActor.run {
            self.viewModel.endGame()
        }

        return .success(result.description)
    }
}

// MARK: - Conversation Engine

@MainActor
final class ConversationEngine: ObservableObject {

    private let providerStore: ProviderStore
    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings

    /// Game view model — set by AppDelegate, used for start_game tool.
    var gameViewModel: GameViewModel?

    /// Max tool-use loop iterations per single turn.
    /// Conversations should be quick — one tool call per turn is expected.
    private static let maxIterationsPerTurn = 5

    @Published private(set) var isConversationActive = false

    /// The running conversation task, stored so it can be cancelled.
    private var conversationTask: Task<Void, Never>?

    // MARK: Init

    init(
        providerStore: ProviderStore,
        viewModel: NotchOverlayViewModel,
        panelController: NotchPanelController,
        settings: OverlaySettings
    ) {
        self.providerStore = providerStore
        self.viewModel = viewModel
        self.panelController = panelController
        self.settings = settings
    }

    // MARK: - Cancel

    /// Cancel the running conversation. Safe to call even if no conversation is active.
    func cancel() {
        conversationTask?.cancel()
        conversationTask = nil
        if isConversationActive {
            isConversationActive = false
            viewModel.collapse()
            viewModel.conversationDismissHandler = nil
            panelController.disableInteraction()
            logger.info("Conversation cancelled by user.")
            LogStore.shared.info("Conversation", "🛑 Conversation cancelled by user")
        }
    }

    // MARK: - Start Conversation

    /// Start a multi-character conversation.
    ///
    /// This method manages the entire lifecycle: setting active state,
    /// alternating turns between participants, and cleaning up.
    ///
    /// - Parameters:
    ///   - participants: The characters participating in the conversation (2+).
    ///   - context: A description of the topic or situation that triggered the conversation.
    ///   - maxTurns: Maximum number of turns before auto-ending.
    ///   - pauseBetweenTurns: Seconds to wait between turns (default 1.0).
    func startConversation(
        participants: [Character],
        context: String,
        maxTurns: Int,
        pauseBetweenTurns: Double = 1.0
    ) {
        guard participants.count >= 2 else {
            logger.warning("Conversation requires at least 2 participants.")
            LogStore.shared.warning(
                "Conversation", "Cannot start — need at least 2 participants")
            return
        }

        guard !isConversationActive else {
            logger.info("Conversation already in progress — skipping.")
            LogStore.shared.warning(
                "Conversation", "Skipping — a conversation is already active")
            return
        }

        conversationTask = Task { [weak self] in
            await self?.runConversation(
                participants: participants,
                context: context,
                maxTurns: maxTurns,
                pauseBetweenTurns: pauseBetweenTurns
            )
        }
    }

    // MARK: - Run Conversation

    /// Internal async implementation of the conversation loop.
    /// Each character's turn is driven by `AgentLoop.run()`.
    private func runConversation(
        participants: [Character],
        context: String,
        maxTurns: Int,
        pauseBetweenTurns: Double
    ) async {
        guard participants.count >= 2 else {
            logger.warning("Conversation requires at least 2 participants.")
            LogStore.shared.warning(
                "Conversation", "Cannot start — need at least 2 participants")
            return
        }

        let participantNames = participants.map { $0.name }.joined(separator: ", ")
        logger.info(
            "Starting conversation between \(participantNames) — context: \(context)")
        LogStore.shared.info(
            "Conversation",
            "🎭 Starting conversation: \(participantNames) — \(context)")

        isConversationActive = true

        // Enable panel interaction for the entire conversation so the
        // DISMISS button is always clickable — even during typewriter.
        panelController.enableInteraction(
            smallMode: settings.smallMode,
            contentHeight: viewModel.interactiveCardHeight
        )

        // Hook into ViewModel so DISMISS kills the conversation.
        viewModel.conversationDismissHandler = { [weak self] in
            self?.cancel()
        }

        defer {
            isConversationActive = false
            conversationTask = nil
            viewModel.conversationDismissHandler = nil
            panelController.disableInteraction()
            logger.info("Conversation ended between \(participantNames).")
            LogStore.shared.info(
                "Conversation", "🎭 Conversation ended: \(participantNames)")
        }

        let transcriptRef = TranscriptRef()

        for turnIndex in 0..<maxTurns {
            guard !Task.isCancelled else { break }

            let character = participants[turnIndex % participants.count]
            let participantIndex = turnIndex % participants.count

            logger.debug(
                "Turn \(turnIndex + 1)/\(maxTurns) — \(character.name)'s turn")
            LogStore.shared.debug(
                "Conversation",
                "Turn \(turnIndex + 1)/\(maxTurns) — \(character.name)")

            // Resolve the LLM client for this character.
            guard
                let resolved = LLMClientResolver.resolve(
                    for: character, providerStore: providerStore)
            else {
                logger.warning(
                    "Skipping \(character.name)'s turn — no provider configured.")
                LogStore.shared.warning(
                    "Conversation",
                    "Skipping \(character.name)'s turn — no provider configured")
                continue
            }

            // Build tools for this turn.
            let tools = buildConversationTools(
                character: character,
                participantIndex: participantIndex,
                participantCount: participants.count,
                transcriptRef: transcriptRef
            )

            // Build the user prompt.
            let userPrompt: String
            if transcriptRef.entries.isEmpty {
                userPrompt =
                    "[CONVERSATION START] Context: \(context)\n\nYou go first. Start the conversation."
            } else {
                userPrompt =
                    "[YOUR TURN] Continue the conversation. React to what was said."
            }

            let systemPrompt = buildConversationSystemPrompt(
                for: character,
                participants: participants,
                transcript: transcriptRef.entries,
                turnIndex: turnIndex,
                maxTurns: maxTurns
            )

            let config = AgentLoopConfig(
                client: resolved.client,
                systemPrompt: systemPrompt,
                maxIterations: Self.maxIterationsPerTurn,
                tools: tools
            )

            var shouldEndConversation = false

            // Compute provider type for usage tracking (also used for dataset logging below).
            let llmConfig = CharacterLLMConfig.load(from: character.directoryURL)
            let providerType =
                providerStore.providers.first(where: { $0.id == llmConfig.providerID })?
                .providerType.rawValue
                ?? providerStore.providers.first?.providerType.rawValue
                ?? "unknown"

            do {
                let result = try await AgentLoop.run(
                    config: config,
                    initialMessages: [.user(userPrompt)],
                    onEvent: { event in
                        if case .turnEnd(let response, _) = event {
                            await UsageTracker.shared.record(
                                characterName: character.name,
                                provider: providerType,
                                model: resolved.model,
                                usage: response.usage
                            )
                        }
                    }
                )

                // Handle fallback text (no tool calls produced a visible message).
                if let text = result.lastTextContent {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count > 5 {
                        logger.info(
                            "Fallback: displaying text-only conversation response as overlay."
                        )
                        LogStore.shared.info(
                            "Conversation",
                            "📢 Fallback overlay for \(character.name)")

                        // Show the fallback text as an overlay.
                        let fallbackArgs: [String: JSONValue] = [
                            "message": .string(trimmed),
                            "face": .string(character.resolvedDefaultFace),
                        ]
                        let fallbackTool = ConversationReplyToTool(
                            viewModel: viewModel,
                            panelController: panelController,
                            settings: settings,
                            character: character,
                            participantIndex: participantIndex,
                            participantCount: participants.count,
                            transcriptRef: transcriptRef
                        )
                        _ = await fallbackTool.execute(arguments: fallbackArgs)
                    }
                }

                // Dataset logging for this character's conversation turn.
                if settings.datasetLogging {
                    DatasetLogger.log(
                        characterName: character.name,
                        systemPrompt: systemPrompt,
                        messages: result.messages,
                        triggerContext: "conversation with \(participantNames) — \(context)",
                        model: resolved.model,
                        provider: providerType
                    )
                }

                // Check if end_conversation was called (tool returned .terminate).
                if result.terminated {
                    shouldEndConversation = true
                }
            } catch {
                logger.error(
                    "AgentLoop failed for \(character.name): \(error.localizedDescription)"
                )
                LogStore.shared.error(
                    "Conversation",
                    "AgentLoop error (\(character.name)): \(error.localizedDescription)"
                )
                shouldEndConversation = true
            }

            if shouldEndConversation {
                break
            }

            // Pause between turns so the user can read what's happening.
            if turnIndex < maxTurns - 1, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pauseBetweenTurns))
            }
        }
    }

    // MARK: - System Prompt

    /// Build the conversation-specific system prompt for a character's turn.
    private func buildConversationSystemPrompt(
        for character: Character,
        participants: [Character],
        transcript: [ConversationTranscriptEntry],
        turnIndex: Int,
        maxTurns: Int
    ) -> String {
        let timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE dd MMMM yyyy — HH'h'mm"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formattedTime = formatter.string(from: Date())

        let faceList = character.faceNames.joined(separator: ", ")

        let otherNames =
            participants
            .filter { $0.name != character.name }
            .map { $0.name }
            .joined(separator: ", ")

        let transcriptText: String
        if transcript.isEmpty {
            transcriptText = "(conversation just started — nothing said yet)"
        } else {
            transcriptText = transcript.map { entry in
                "[\(entry.speaker)]: \(entry.message)"
            }.joined(separator: "\n")
        }

        // Phase 0.5: Load user context file if it exists.
        let userContext = Self.loadUserContext()

        return """
            You are \(character.name), a character living inside the user's computer.
            You appear as a small widget dropping from the macOS notch.

            ## Your personality
            \(character.personality)
            \(userContext.map { "\n            ## User Context\n            \($0)" } ?? "")

            ## Current time
            \(formattedTime) (\(timeZone.identifier))

            ## Available faces
            You MUST pick one of these for every message you send: \(faceList)
            Choose the face that best matches the emotion of what you're saying.

            ## Conversation
            You are having a conversation WITH \(otherNames) — another character who lives in the notch, just like you.
            You are NOT talking to the user. You are talking to \(otherNames). Address them directly by name.
            The user is just watching you two chat. Do NOT address the user, do NOT say "Master", do NOT talk to the human.
            Turn \(turnIndex + 1) of \(maxTurns).

            Conversation so far:
            \(transcriptText)

            ## Guidelines
            - Stay in character at ALL times.
            - Keep messages short and punchy (1-2 sentences).
            - You are chatting with \(otherNames). Talk TO them, react to what THEY said.
            - Use reply_to to send your message in the conversation.
            - Use end_conversation when the exchange feels complete or you want to wrap up.
            - Do NOT talk to the user. This is a conversation between characters only.
            - Be natural and conversational. Banter, tease, joke, disagree — be lively.
            - You MUST call exactly one of: reply_to or end_conversation.
            - IMPORTANT: When calling tools, always specify the `face` parameter FIRST in your arguments, before `message`.
            """
    }

    // MARK: - User Context (Phase 0.5)

    /// Load the user context file from `~/.akiapp/context.md` if it exists.
    private static func loadUserContext() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let contextURL =
            homeDir
            .appendingPathComponent(".akiapp", isDirectory: true)
            .appendingPathComponent("context.md")

        guard FileManager.default.fileExists(atPath: contextURL.path) else {
            return nil
        }

        do {
            let content = try String(contentsOf: contextURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : content
        } catch {
            logger.warning("Failed to read ~/.akiapp/context.md: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Tool Definitions

    /// Build conversation-specific tools for a character's turn.
    private func buildConversationTools(
        character: Character,
        participantIndex: Int,
        participantCount: Int,
        transcriptRef: TranscriptRef
    ) -> [any AgentTool] {
        return [
            ConversationReplyToTool(
                viewModel: viewModel,
                panelController: panelController,
                settings: settings,
                character: character,
                participantIndex: participantIndex,
                participantCount: participantCount,
                transcriptRef: transcriptRef
            ),
            ConversationEndTool(
                viewModel: viewModel,
                panelController: panelController,
                settings: settings,
                character: character,
                participantIndex: participantIndex,
                participantCount: participantCount,
                transcriptRef: transcriptRef
            ),
            ConversationStartGameTool(
                viewModel: viewModel,
                panelController: panelController,
                settings: settings,
                character: character,
                gameViewModel: gameViewModel
            ),
        ]
    }
}
