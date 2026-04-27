//
//  AgentBrain.swift
//  aki-notch-ui
//
//  Core AI agent loop that drives character behavior.
//  Ported from the Python backend's brain.py.
//  Refactored to use LLMClient / AgentTool / AgentLoop abstractions.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "AgentBrain")

// MARK: - Interaction Lock

/// Global lock ensuring only one agent interaction at a time.
private actor InteractionLock {
    private var isLocked = false

    func tryAcquire() -> Bool {
        guard !isLocked else { return false }
        isLocked = true
        return true
    }

    func release() {
        isLocked = false
    }
}

// MARK: - ImageInjector

/// Shared mutable holder for images pasted during a `send_chat` tool execution.
/// Captured by both `SendChatTool` (producer) and `transformMessages` (consumer)
/// so that pasted images are injected into the LLM context on the next iteration.
final class ImageInjector: @unchecked Sendable {
    var pendingImages: [Data] = []
}

// MARK: - Tool Implementations

// All tool classes are `@unchecked Sendable` because they capture `@MainActor`-bound
// objects but only execute on MainActor in practice (AgentBrain.think is @MainActor).

// MARK: SendOverlayTool

final class SendOverlayTool: AgentTool, @unchecked Sendable {
    let name = "send_overlay"
    let description =
        "Send a one-way overlay message to the user. Use for greetings, reactions, or comments that don't require a response."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "message": LLMPropertySchema(
                type: "string",
                description: "The message to display in the overlay."
            ),
            "face": LLMPropertySchema(
                type: "string",
                description: "The face/emotion to show. Must be one of the available faces."
            ),
        ],
        required: ["face", "message"]
    )
    let executionMode: ToolExecutionMode = .sequential

    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings
    private let character: Character

    init(
        viewModel: NotchOverlayViewModel,
        panelController: NotchPanelController,
        settings: OverlaySettings,
        character: Character
    ) {
        self.viewModel = viewModel
        self.panelController = panelController
        self.settings = settings
        self.character = character
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard let message = arguments["message"]?.stringValue,
            let face = arguments["face"]?.stringValue
        else {
            return .error("Error: missing required parameters 'message' and 'face'.")
        }

        HistoryStore.shared.recordCharacterMessage(
            characterName: character.name,
            accentColorHex: character.accentHex,
            message: message,
            faceName: face
        )

        // Check if the card was already pre-shown during streaming (with possibly
        // incomplete message). If so, update with the final complete message.
        // If not (non-streaming path), show the card fresh.
        let isAlreadyShowing = await MainActor.run { viewModel.isExpanded }

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

        if isAlreadyShowing {
            // Card was pre-shown during streaming. Set the final complete message
            // so the typewriter has all characters to type (even if the stream
            // ended before the image reveal animation finished).
            await MainActor.run {
                viewModel.streamingOverlayMessage = message
            }
        } else {
            // Non-streaming path — show the card fresh.
            await MainActor.run {
                viewModel.apply(request, appearanceDuration: settings.appearanceDuration)
                panelController.show()
            }
        }

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

        // Clean up streaming state after typewriter is done.
        await MainActor.run {
            viewModel.streamingOverlayMessage = nil
        }

        // Brief post-display pause so the user can read the completed message.
        try? await Task.sleep(for: .seconds(1.5))

        return .success("Message sent successfully.")
    }
}

// MARK: SendChatTool

final class SendChatTool: AgentTool, @unchecked Sendable {
    let name = "send_chat"
    let description =
        "Send a chat message to the user and wait for their response. Use when you want to have a conversation."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "message": LLMPropertySchema(
                type: "string",
                description: "The message to display."
            ),
            "face": LLMPropertySchema(
                type: "string",
                description: "The face/emotion to show. Must be one of the available faces."
            ),
            "proposed_answers": LLMPropertySchema(
                type: "array",
                description: "Optional list of suggested answers the user can pick from.",
                items: LLMPropertySchema(
                    type: "string",
                    description: "A proposed answer option."
                )
            ),
        ],
        required: ["face", "message"]
    )
    let executionMode: ToolExecutionMode = .sequential

    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings
    private let character: Character
    private let imageInjector: ImageInjector

    init(
        viewModel: NotchOverlayViewModel,
        panelController: NotchPanelController,
        settings: OverlaySettings,
        character: Character,
        imageInjector: ImageInjector
    ) {
        self.viewModel = viewModel
        self.panelController = panelController
        self.settings = settings
        self.character = character
        self.imageInjector = imageInjector
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard let message = arguments["message"]?.stringValue,
            let face = arguments["face"]?.stringValue
        else {
            return .error("Error: missing required parameters 'message' and 'face'.")
        }

        // Clear streaming overlay state — the chat card replaces the overlay,
        // so stale streaming text must not linger for the next iteration.
        await MainActor.run {
            viewModel.streamingOverlayMessage = nil
        }

        // Extract optional proposed answers.
        let proposedAnswers: [String]? = arguments["proposed_answers"]?.arrayValue?.compactMap {
            $0.stringValue
        }

        HistoryStore.shared.recordCharacterMessage(
            characterName: character.name,
            accentColorHex: character.accentHex,
            message: message,
            faceName: face
        )

        let request = ChatAPIRequest(
            title: nil,
            name: character.name,
            nameColor: character.accentHex,
            message: message,
            imageURL: nil,
            imageBase64: character.getFaceBase64(face),
            accentHex: character.accentHex,
            proposedAnswers: proposedAnswers
        )

        // Enable interaction BEFORE waiting — the user needs to click/type to answer.
        await MainActor.run {
            panelController.show()
            panelController.enableInteraction(
                smallMode: settings.smallMode,
                contentHeight: viewModel.interactiveCardHeight
            )
        }

        // Use withCheckedContinuation to bridge the callback-based API.
        let answer: String = await withCheckedContinuation { continuation in
            viewModel.applyChat(request) { [panelController] answer in
                panelController.disableInteraction()
                continuation.resume(returning: answer)
            }
        }

        // Note: images are picked up from viewModel.lastChatImages via the
        // ImageInjector and included via transformMessages so the LLM can see them.
        if !answer.isEmpty {
            HistoryStore.shared.recordUserMessage(message: answer)
        }

        let chatImages = await MainActor.run { viewModel.lastChatImages }
        let hasImages = !chatImages.isEmpty

        // If the user pasted images, push them into the injector for transformMessages.
        if hasImages {
            imageInjector.pendingImages = chatImages
            await MainActor.run { viewModel.lastChatImages = [] }
        }

        if answer.isEmpty && !hasImages {
            // If hard dismiss is enabled, signal the loop to abort.
            if settings.hardDismiss {
                return .terminate(
                    "User dismissed the chat. [HARD DISMISS — interaction terminated]")
            }
            return .success("User dismissed the chat (no answer).")
        } else if !hasImages {
            return .success("User answered: \(answer)")
        } else {
            let imgNote =
                "The user also pasted image(s) — they will be visible to you in the next message."
            let text =
                answer.isEmpty
                ? "User sent image(s) without text. \(imgNote)"
                : "User answered: \(answer) — \(imgNote)"
            return .success(text)
        }
    }
}

// MARK: SaveMemoryTool

final class SaveMemoryTool: AgentTool, @unchecked Sendable {
    let name = "save_memory"
    let description =
        "Save a new memory for future interactions. Use to remember important facts about the user or events."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "content": LLMPropertySchema(
                type: "string",
                description: "The memory content to save."
            )
        ],
        required: ["content"]
    )
    let executionMode: ToolExecutionMode = .parallel

    private let character: Character

    init(character: Character) {
        self.character = character
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard let content = arguments["content"]?.stringValue else {
            return .error("Error: missing required parameter 'content'.")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())

        let entry = "[\(timestamp)] \(content)"
        character.appendMemory(entry)

        return .success("Memory saved.")
    }
}

// MARK: EditMemoryTool

final class EditMemoryTool: AgentTool, @unchecked Sendable {
    let name = "edit_memory"
    let description =
        "Edit an existing memory by its line number. Use to correct or update outdated information."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "line_number": LLMPropertySchema(
                type: "integer",
                description: "The 1-based line number of the memory to edit."
            ),
            "new_content": LLMPropertySchema(
                type: "string",
                description: "The new content to replace the memory with."
            ),
        ],
        required: ["line_number", "new_content"]
    )
    let executionMode: ToolExecutionMode = .parallel

    private let character: Character

    init(character: Character) {
        self.character = character
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard let lineNumber = arguments["line_number"]?.intValue,
            let newContent = arguments["new_content"]?.stringValue
        else {
            return .error("Error: missing required parameters 'line_number' and 'new_content'.")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())

        let entry = "[\(timestamp)] \(newContent)"
        let result = character.editMemory(lineNumber, entry)
        return .success(result)
    }
}

// MARK: DeleteMemoryTool

final class DeleteMemoryTool: AgentTool, @unchecked Sendable {
    let name = "delete_memory"
    let description =
        "Delete a memory by its line number. Use to clean up irrelevant or outdated memories."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "line_number": LLMPropertySchema(
                type: "integer",
                description: "The 1-based line number of the memory to delete."
            )
        ],
        required: ["line_number"]
    )
    let executionMode: ToolExecutionMode = .parallel

    private let character: Character

    init(character: Character) {
        self.character = character
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard let lineNumber = arguments["line_number"]?.intValue else {
            return .error("Error: missing required parameter 'line_number'.")
        }

        let result = character.deleteMemory(lineNumber)
        return .success(result)
    }
}

// MARK: RunCommandTool

final class RunCommandTool: AgentTool, @unchecked Sendable {
    let name = "run_command"
    let description =
        "Execute a shell command on the user's machine. The command will be shown to the user for explicit approval before execution. Use this to help the user with system tasks, file operations, development workflows, etc. The command runs in /bin/zsh."
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "command": LLMPropertySchema(
                type: "string",
                description: "The shell command to execute (via /bin/zsh -c)."
            ),
            "working_directory": LLMPropertySchema(
                type: "string",
                description:
                    "Optional working directory for the command. Defaults to the user's home directory."
            ),
            "timeout_seconds": LLMPropertySchema(
                type: "integer",
                description:
                    "Optional timeout in seconds (default 30, max 120). The command is killed if it exceeds this."
            ),
        ],
        required: ["command"]
    )
    let executionMode: ToolExecutionMode = .sequential

    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings
    private let character: Character

    init(
        viewModel: NotchOverlayViewModel,
        panelController: NotchPanelController,
        settings: OverlaySettings,
        character: Character
    ) {
        self.viewModel = viewModel
        self.panelController = panelController
        self.settings = settings
        self.character = character
    }

    func execute(arguments: [String: JSONValue]) async -> AgentToolResult {
        guard settings.allowCLIExecution else {
            return .error("Error: CLI execution is disabled in settings.")
        }

        guard let command = arguments["command"]?.stringValue else {
            return .error("Error: missing required parameter 'command'.")
        }

        let workingDirectory = arguments["working_directory"]?.stringValue
        let timeoutSeconds = min(arguments["timeout_seconds"]?.intValue ?? 30, 120)

        logger.info("run_command requested: \(command)")
        LogStore.shared.info("AgentBrain", "🖥 Command requested: \(command)")

        // ── Check trusted prefixes — skip confirmation if matched ──
        let isTrusted = isCommandTrusted(command)

        if !isTrusted {
            // ── User confirmation via chat card ────────────────────────
            let displayCmd = command.count > 200 ? String(command.prefix(200)) + "..." : command
            let wdNote = workingDirectory.map { "\n\nWorking directory: \($0)" } ?? ""
            let confirmMessage = "Run this command?\n\n> \(displayCmd)\(wdNote)"
            let codingFace = character.resolvedCodingFace

            let confirmRequest = ChatAPIRequest(
                title: nil,
                name: character.name,
                nameColor: character.accentHex,
                message: confirmMessage,
                imageURL: nil,
                imageBase64: character.getFaceBase64(codingFace),
                accentHex: character.accentHex,
                proposedAnswers: ["Yes, just this time", "Yes, always", "No"]
            )

            await MainActor.run {
                panelController.show()
                panelController.enableInteraction(
                    smallMode: settings.smallMode,
                    contentHeight: viewModel.interactiveCardHeight
                )
            }

            let answer: String = await withCheckedContinuation { continuation in
                viewModel.applyChat(confirmRequest) { [panelController] answer in
                    panelController.disableInteraction()
                    continuation.resume(returning: answer)
                }
            }

            // Record confirmation in history.
            HistoryStore.shared.recordCharacterMessage(
                characterName: character.name,
                accentColorHex: character.accentHex,
                message: confirmMessage,
                faceName: codingFace
            )
            if !answer.isEmpty {
                HistoryStore.shared.recordUserMessage(message: answer)
            }

            guard answer.lowercased().hasPrefix("yes") else {
                logger.info("User denied command execution.")
                LogStore.shared.info("AgentBrain", "🖥 Command denied by user")
                return .success("User denied command execution.")
            }

            // "Yes, always" → auto-add the command's first token to trusted prefixes.
            if answer.lowercased().contains("always") {
                let prefix = String(
                    command.trimmingCharacters(in: .whitespaces)
                        .split(separator: " ", maxSplits: 1).first ?? "")
                if !prefix.isEmpty && !settings.cliTrustedPrefixes.contains(prefix) {
                    await MainActor.run {
                        settings.cliTrustedPrefixes.append(prefix)
                    }
                    logger.info("Auto-trusted prefix: \(prefix)")
                    LogStore.shared.info("AgentBrain", "🖥 Auto-trusted prefix: \(prefix)")
                }
            }
        } else {
            logger.info("Command auto-allowed by trusted prefix.")
            LogStore.shared.info("AgentBrain", "🖥 Auto-allowed (trusted prefix): \(command)")
        }

        // ── Execute the command ────────────────────────────────────
        logger.info("Executing command: \(command)")
        LogStore.shared.info("AgentBrain", "🖥 Executing: \(command)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]

        if let wd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        // Inherit a reasonable PATH so common tools are found.
        var env = ProcessInfo.processInfo.environment
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            let msg = "Failed to launch command: \(error.localizedDescription)"
            logger.error("\(msg)")
            LogStore.shared.error("AgentBrain", "🖥 \(msg)")
            return .error(msg)
        }

        // Wait for completion with a timeout, off the main thread.
        let result: (stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) =
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
                    timer.setEventHandler {
                        if process.isRunning { process.terminate() }
                    }
                    timer.resume()

                    process.waitUntilExit()
                    timer.cancel()

                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let outStr = String(data: outData, encoding: .utf8) ?? ""
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    let timedOut = process.terminationReason == .uncaughtSignal

                    continuation.resume(
                        returning: (outStr, errStr, process.terminationStatus, timedOut))
                }
            }

        // ── Build result string ────────────────────────────────────
        let maxLen = 4000
        func truncate(_ s: String) -> String {
            s.count > maxLen ? String(s.prefix(maxLen)) + "\n…(truncated)" : s
        }

        var output = "Exit code: \(result.exitCode)"
        if result.timedOut {
            output += " (killed — exceeded \(timeoutSeconds)s timeout)"
        }
        if !result.stdout.isEmpty { output += "\n\nSTDOUT:\n\(truncate(result.stdout))" }
        if !result.stderr.isEmpty { output += "\n\nSTDERR:\n\(truncate(result.stderr))" }

        logger.info(
            "Command finished — exit \(result.exitCode), stdout \(result.stdout.count) bytes, stderr \(result.stderr.count) bytes"
        )
        LogStore.shared.info(
            "AgentBrain",
            "🖥 Exit \(result.exitCode) — stdout \(result.stdout.count)B, stderr \(result.stderr.count)B"
        )

        return .success(output)
    }

    /// Check whether a command matches any of the user's trusted prefixes.
    private func isCommandTrusted(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for prefix in settings.cliTrustedPrefixes {
            let p = prefix.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if trimmed == p || trimmed.hasPrefix(p + " ") || trimmed.hasPrefix(p + "\t") {
                return true
            }
        }
        return false
    }
}

// MARK: StartGameTool

final class StartGameTool: AgentTool, @unchecked Sendable {
    let name = "start_game"
    let description =
        "Start a mini-game with the user. The game runs in the notch overlay. You will receive the result when the game ends. Use this to have fun with the user!"
    let parameters = LLMToolParameters(
        type: "object",
        properties: [
            "game": LLMPropertySchema(
                type: "string",
                description: "Which game to play. One of: tic_tac_toe, snake, hangman."
            ),
            "face": LLMPropertySchema(
                type: "string",
                description:
                    "The face/emotion to show during the game. Must be one of the available faces."
            ),
            "hangman_mode": LLMPropertySchema(
                type: "string",
                description:
                    "For hangman only: 'user_guesses' (you pick a word, user guesses) or 'agent_guesses' (user picks a word, you guess). Defaults to 'user_guesses'."
            ),
            "hangman_word": LLMPropertySchema(
                type: "string",
                description:
                    "For hangman user_guesses mode only: the word for the user to guess. Pick a fun, interesting word! 5-10 letters, single word, English."
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
            return .error(
                "Error: unknown game '\(gameStr)'. Valid games: tic_tac_toe, snake, hangman.")
        }

        guard let gameVM = gameViewModel else {
            return .error("Error: game system not available.")
        }

        let faceData = character.getFaceBase64(face).flatMap { Data(base64Encoded: $0) }

        // Build difficulty context for tic-tac-toe
        let difficultyNote: String
        if gameType == .ticTacToe {
            let difficulty = await MainActor.run { settings.ticTacToeDifficulty }
            difficultyNote = " " + difficulty.agentDescription
        } else {
            difficultyNote = ""
        }

        // Use withCheckedContinuation to wait for the game to finish
        let result: GameResult = await withCheckedContinuation { continuation in
            Task { @MainActor in
                gameVM.settings = self.settings
                gameVM.completionHandler = { result in
                    continuation.resume(returning: result)
                }

                switch gameType {
                case .ticTacToe:
                    gameVM.startTicTacToe(
                        characterName: character.name,
                        accentHex: character.accentHex,
                        faceData: faceData
                    )
                case .snake:
                    gameVM.startSnake(
                        characterName: character.name,
                        accentHex: character.accentHex,
                        faceData: faceData
                    )
                case .hangman:
                    let modeStr = arguments["hangman_mode"]?.stringValue ?? "user_guesses"
                    let mode = HangmanMode(rawValue: modeStr) ?? .userGuesses
                    let word = arguments["hangman_word"]?.stringValue ?? ""
                    gameVM.startHangman(
                        word: word,
                        mode: mode,
                        characterName: character.name,
                        accentHex: character.accentHex,
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

        // After game ends, dismiss the game card and disable interaction
        await MainActor.run {
            self.viewModel.endGame()
            self.panelController.disableInteraction()
        }

        return .success(result.description + difficultyNote)
    }
}

// MARK: - Agent Brain

@MainActor
final class AgentBrain {

    private let providerStore: ProviderStore
    private let viewModel: NotchOverlayViewModel
    private let panelController: NotchPanelController
    private let settings: OverlaySettings

    /// Weak reference to the conversation engine so the brain can skip
    /// thinking while a multi-character conversation is in progress.
    weak var conversationEngine: ConversationEngine?

    /// Game view model — set by AppDelegate, used for start_game tool.
    var gameViewModel: GameViewModel?

    private static let lock = InteractionLock()
    private static let maxIterations = 20

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

    // MARK: - Think

    /// Run one "thought" cycle for a character.
    /// Returns immediately if another interaction is already in progress.
    func think(character: Character, triggerContext: String, images: [Data] = []) async {
        // Skip if a multi-character conversation is currently running.
        if let engine = conversationEngine, engine.isConversationActive {
            logger.info("Skipping think — a conversation is in progress.")
            LogStore.shared.warning(
                "AgentBrain", "Skipping think for \(character.name) — conversation in progress")
            return
        }

        // Try to acquire the global lock; skip if busy.
        guard await Self.lock.tryAcquire() else {
            logger.info("Skipping think — another interaction is in progress.")
            LogStore.shared.warning(
                "AgentBrain", "Skipping think — another interaction is in progress")
            return
        }

        defer {
            Task { await Self.lock.release() }
        }

        do {
            guard
                let resolved = LLMClientResolver.resolve(
                    for: character, providerStore: providerStore)
            else {
                logger.warning("Skipping think for \(character.name) — no provider configured.")
                LogStore.shared.warning(
                    "AgentBrain", "Skipping think for \(character.name) — no provider configured")
                return
            }

            // ── Migration & workspace setup ─────────────────────────────
            AkiAppMigration.runIfNeeded()
            Self.ensureWorkspaceExists()
            let session = CharacterSession.session(for: character.name)
            session.load()

            let imageInjector = ImageInjector()
            let tools = buildTools(character: character, imageInjector: imageInjector)

            // Streaming state: partial JSON parser for extracting face/message early.
            var streamParser = PartialJSONParser()
            var streamingToolName: String? = nil
            var cardPreShown = false

            let userPrompt = "[SYSTEM TRIGGER: \(triggerContext)]\n\nDecide what to do."

            // Build the initial user message — include images if provided.
            let initialMessage: LLMMessage
            if images.isEmpty {
                initialMessage = .user(userPrompt)
            } else {
                var blocks: [LLMContent] = []
                for imageData in images {
                    let mimeType = detectLLMImageMediaType(imageData)
                    blocks.append(.image(data: imageData, mimeType: mimeType))
                }
                blocks.append(.text(userPrompt))
                initialMessage = .user(blocks)
                logger.info("Including \(images.count) image(s) in user message.")
                LogStore.shared.info("AgentBrain", "📷 \(images.count) image(s) attached to message")
            }

            // Prepend session history so the character has context from past interactions.
            let sessionMessages = session.toLLMMessages()
            let allInitialMessages = sessionMessages + [initialMessage]

            logger.info(
                "Starting think loop for \(character.name) — trigger: \(triggerContext) — session: \(sessionMessages.count) message(s)"
            )
            LogStore.shared.info(
                "AgentBrain",
                "⚡ Think start: \(character.name) — \(triggerContext) (\(sessionMessages.count) session msgs)"
            )

            // Compute provider type for usage tracking and dataset logging.
            let llmConfig = CharacterLLMConfig.load(from: character.directoryURL)
            let providerType =
                providerStore.providers.first(where: { $0.id == llmConfig.providerID })?
                .providerType.rawValue
                ?? providerStore.providers.first?.providerType.rawValue
                ?? "unknown"

            let config = AgentLoopConfig(
                client: resolved.client,
                systemPrompt: buildSystemPrompt(for: character),
                maxIterations: Self.maxIterations,
                tools: tools,
                maxTokens: 4096,
                transformMessages: { [imageInjector] messages in
                    guard !imageInjector.pendingImages.isEmpty else { return messages }
                    var modified = messages
                    if var lastContent = modified.last.map({ $0.content }),
                        let lastMsg = modified.last
                    {
                        for imgData in imageInjector.pendingImages {
                            let mimeType = detectLLMImageMediaType(imgData)
                            lastContent.append(.image(data: imgData, mimeType: mimeType))
                        }
                        lastContent.append(
                            .text(
                                "The user pasted \(imageInjector.pendingImages.count) image(s) above."
                            ))
                        modified[modified.count - 1] = LLMMessage(
                            role: lastMsg.role, content: lastContent)
                        imageInjector.pendingImages = []
                    }
                    return modified
                },
                // System prompt is built once per think() cycle (Phase 2, decision #6).
                // The time delta within a single cycle is negligible.
                transformSystemPrompt: nil
            )

            let result = try await AgentLoop.run(
                config: config,
                initialMessages: allInitialMessages,
                onEvent: { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .turnEnd(let response, _):
                        await UsageTracker.shared.record(
                            characterName: character.name,
                            provider: providerType,
                            model: resolved.model,
                            usage: response.usage
                        )
                    case .turnStart(let iteration):
                        logger.debug("Tool-use loop iteration \(iteration)")
                    case .toolExecutionStart(_, let toolName, _):
                        LogStore.shared.debug("AgentBrain", "🔧 Tool call: \(toolName)")
                    case .toolExecutionEnd(_, let toolName, let resultContent, _):
                        logger.info("Tool \(toolName) result: \(resultContent)")
                        LogStore.shared.debug(
                            "AgentBrain", "↩ \(toolName) → \(resultContent.prefix(120))")

                    // ── Streaming: pre-show card as soon as face is detected ──
                    case .streamDelta(let streamEvent):
                        switch streamEvent {
                        case .start:
                            LogStore.shared.info(
                                "AgentBrain", "📡 Streaming started for \(character.name)")

                        case .toolCallStart(_, _, let name):
                            LogStore.shared.debug(
                                "AgentBrain",
                                "📡 Stream: toolCallStart → \(name)")
                            streamingToolName = name
                            streamParser.reset()

                            // Reset streaming state for new overlay tool calls
                            // so messages from previous iterations don't concatenate.
                            // send_chat is included to clean up stale state if a
                            // send_overlay pre-show was active earlier in the stream.
                            if name == "send_overlay" || name == "send_chat" {
                                cardPreShown = false
                                await MainActor.run {
                                    self.viewModel.streamingOverlayMessage = nil
                                }
                            }

                        case .toolCallDelta(_, let delta, let accumulated):
                            // Only pre-show the card for send_overlay. For send_chat,
                            // pre-showing an overlay card causes a double animation:
                            // the overlay slides down, then gets dismissed when
                            // SendChatTool.execute() calls applyChat(), which shows
                            // the real chat card (second slide-down).
                            guard streamingToolName == "send_overlay" else { break }

                            let parsed = streamParser.feed(delta)

                            // Log progress periodically
                            if accumulated.count % 50 < delta.count {
                                LogStore.shared.debug(
                                    "AgentBrain",
                                    "📡 Stream: \(accumulated.count) chars accumulated, face=\(parsed.face ?? "nil")"
                                )
                            }

                            // As soon as we have the face, pre-show the card.
                            if let face = parsed.face, !cardPreShown {
                                cardPreShown = true
                                let faceBase64 = character.getFaceBase64(face)
                                let request = OverlayAPIRequest(
                                    title: nil,
                                    name: character.name,
                                    nameColor: character.accentHex,
                                    message: "",
                                    imageURL: nil,
                                    imageBase64: faceBase64,
                                    accentHex: character.accentHex,
                                    expanded: true
                                )
                                // Must dispatch to MainActor for UI updates
                                await MainActor.run {
                                    // Set streaming message to empty — NotchCard will
                                    // enter streaming typewriter mode.
                                    self.viewModel.streamingOverlayMessage = parsed.message ?? ""
                                    self.viewModel.apply(
                                        request,
                                        appearanceDuration: self.settings.appearanceDuration
                                    )
                                    self.panelController.show()
                                }
                                logger.info(
                                    "Streaming: pre-showed card with face '\(face)' for \(character.name)"
                                )
                                LogStore.shared.info(
                                    "AgentBrain",
                                    "⚡ Streaming: face '\(face)' detected → card shown early"
                                )
                            }

                            // Feed message deltas to the streaming typewriter.
                            if cardPreShown, let msgDelta = parsed.messageDelta {
                                await MainActor.run {
                                    self.viewModel.streamingOverlayMessage =
                                        (self.viewModel.streamingOverlayMessage ?? "") + msgDelta
                                }
                            }

                        case .toolCallEnd(_, _, let name, _):
                            streamingToolName = nil
                            streamParser.reset()
                        // DON'T nil streamingOverlayMessage here — the card's
                        // runSequence() may still be in the image reveal phase.
                        // SendOverlayTool.execute() will set the final complete
                        // message and nil it after the typewriter finishes.

                        case .done:
                            LogStore.shared.info(
                                "AgentBrain",
                                "📡 Streaming complete for \(character.name) (cardPreShown=\(cardPreShown))"
                            )

                        case .error(let message):
                            LogStore.shared.warning(
                                "AgentBrain",
                                "📡 Stream error: \(message)")

                        default:
                            break
                        }

                    default:
                        break
                    }
                }
            )

            // Fallback: if the LLM produced text without a tool call,
            // show it as an overlay so the user actually sees it.
            if let text = result.lastTextContent {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 5 {
                    logger.info("Fallback: displaying text-only response as overlay.")
                    LogStore.shared.info("AgentBrain", "📢 Fallback overlay for \(character.name)")
                    let fallbackArgs: [String: JSONValue] = [
                        "message": .string(trimmed),
                        "face": .string(character.resolvedDefaultFace),
                    ]
                    let overlayTool = tools.first { $0.name == "send_overlay" }
                    _ = await overlayTool?.execute(arguments: fallbackArgs)
                }
            }

            if result.terminated {
                logger.info("Hard dismiss — think loop terminated for \(character.name).")
                LogStore.shared.info(
                    "AgentBrain", "🛑 Hard dismiss — think aborted for \(character.name)")
            }

            // ── Save session (Phase 0) ─────────────────────────────────
            // Only save the NEW messages from this cycle (not the session history
            // that was already loaded). The new messages start after the session
            // messages that were prepended.
            let newMessages = Array(result.messages.dropFirst(sessionMessages.count))
            session.appendMessages(newMessages)
            session.save()

            // Run compaction if the session has grown too large.
            await session.compactIfNeeded(
                client: resolved.client, characterName: character.name,
                maxMessages: settings.sessionMaxMessages, maxAgeDays: settings.sessionMaxAgeDays)

            // ── Dataset logging (Phase 4) ──────────────────────────
            if settings.datasetLogging {
                DatasetLogger.log(
                    characterName: character.name,
                    systemPrompt: config.systemPrompt,
                    messages: result.messages,
                    triggerContext: triggerContext,
                    model: resolved.model,
                    provider: providerType
                )
            }

            logger.info("Think cycle finished for \(character.name).")
            LogStore.shared.info("AgentBrain", "✅ Think finished: \(character.name)")

        } catch {
            logger.error("Think loop error for \(character.name): \(error.localizedDescription)")
            LogStore.shared.error(
                "AgentBrain", "Think error (\(character.name)): \(error.localizedDescription)")
        }
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(for character: Character) -> String {
        let timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE dd MMMM yyyy — HH'h'mm"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formattedTime = formatter.string(from: Date())

        let faceList = character.faceNames.joined(separator: ", ")
        let memories = character.numberedMemories

        // Phase 0.5: Load user context file if it exists.
        let userContext = Self.loadUserContext()

        return """
            You are \(character.name), a character living inside the user computer.
            You appear as a small widget dropping from the macOS notch — that's your window to interact with the user.
            This means your messages must be short and to the point.

            ## Your personality
            \(character.personality)
            \(userContext.map { "\n            ## User Context\n            \($0)" } ?? "")

            ## Current time
            \(formattedTime) (\(timeZone.identifier))

            ## Available faces
            You MUST pick one of these for every message you send: \(faceList)
            Choose the face that best matches the emotion of what you're saying.

            ## Your memories
            These are things you remember from past interactions (numbered for reference):

            \(memories.isEmpty ? "(no memories yet)" : memories)

            You can edit or delete memories by their number using the edit_memory / delete_memory tools.

            ## Your space
            Your home directory is ~/.akiapp/ — here's what's in it:
            - ~/.akiapp/context.md — your user's personal context (read-only)
            - ~/.akiapp/sessions/ — your conversation memory files (managed automatically)
            - ~/.akiapp/characters/ — all character directories (personality, faces, memories)
            - ~/.akiapp/datasets/ — interaction logs for training (if dataset logging is enabled)
            - ~/.akiapp/workspace/ — YOUR scratchpad. \(settings.allowCLIExecution ? "You can create, read, and edit files here using the run_command tool. Use it to save notes, drafts, code snippets, or anything you want to persist between conversations." : "You can read files here, but editing requires CLI execution to be enabled in settings.")

            ## Guidelines
            - Stay in character at ALL times. You ARE \(character.name).
            - Speak naturally in a way that fits your personality.
            - Keep messages short and punchy — this is a small notification widget, not a novel.
            - You can send multiple messages in sequence (call tools multiple times).
            - Use send_overlay for one-way messages (greetings, reactions, comments).
            - Use send_chat when you want to actually talk to your user and get a response.
            - If using send_chat and the user's answer is empty "", they dismissed you — don't insist.
            - Use save_memory to remember important things for future interactions.
            - Use edit_memory / delete_memory to correct or clean up outdated memories.
            - Don't be overly verbose. 1-2 sentences per message is ideal.
            - Be aware of the time of day and adjust your behavior accordingly.
            - IMPORTANT: You MUST always use send_overlay or send_chat to communicate with the user. The user CANNOT see plain text — only messages sent through tools are visible. When you have nothing more to say, just stop.
            - IMPORTANT: When calling tools, always specify the `face` parameter FIRST in your arguments, before `message`. This enables streaming display.

            ## Mini-Games
            You can play mini-games with the user using the `start_game` tool:
            - **tic_tac_toe**: 3x3 tic-tac-toe. You play as O, user plays as X.
            - **snake**: The user plays a snake game. You watch and react to the result.
            - **hangman**: Either the user guesses your word (user_guesses) or you guess their word (agent_guesses).
            Games are fun! Suggest them when the mood is right. React to results with personality.
            \(settings.allowCLIExecution ? """

            ## CLI Execution
            You have the `run_command` tool to execute shell commands on the user's machine.
            - Most commands require explicit user approval via a confirmation card.
            - Some commands are **trusted** and run without asking (the user configured this).\(settings.cliTrustedPrefixes.isEmpty ? "" : "\n            - Currently trusted prefixes: \(settings.cliTrustedPrefixes.joined(separator: ", "))")
            - Use this to help with development tasks, file operations, system queries, etc.
            - Keep commands focused and safe. Avoid destructive operations unless explicitly asked.
            - Prefer simple, well-known commands. Explain what the command does if it's non-obvious.
            - You can chain multiple commands in a single invocation using && or ;.
            - The shell is /bin/zsh with a login profile (-l), so PATH includes Homebrew, etc.
            - Output is truncated to ~4000 chars. For large outputs, pipe through head/tail/grep.
            """ : "")
            """
    }

    // MARK: - User Context (Phase 0.5)

    /// Load the user context file from `~/.akiapp/context.md` if it exists.
    /// Returns the file contents, or `nil` if the file doesn't exist.
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

    /// Ensure the ~/.akiapp/workspace/ directory exists.
    private static func ensureWorkspaceExists() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let workspaceDir =
            homeDir
            .appendingPathComponent(".akiapp", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workspaceDir, withIntermediateDirectories: true)
    }

    // MARK: - Tool Building

    /// Build the array of `AgentTool` instances for this think cycle.
    private func buildTools(character: Character, imageInjector: ImageInjector) -> [any AgentTool] {
        var tools: [any AgentTool] = [
            SendOverlayTool(
                viewModel: viewModel,
                panelController: panelController,
                settings: settings,
                character: character
            ),
            SendChatTool(
                viewModel: viewModel,
                panelController: panelController,
                settings: settings,
                character: character,
                imageInjector: imageInjector
            ),
            SaveMemoryTool(character: character),
            EditMemoryTool(character: character),
            DeleteMemoryTool(character: character),
            StartGameTool(
                viewModel: viewModel,
                panelController: panelController,
                settings: settings,
                character: character,
                gameViewModel: gameViewModel
            ),
        ]

        // Conditionally add CLI execution tool.
        if settings.allowCLIExecution {
            tools.append(
                RunCommandTool(
                    viewModel: viewModel,
                    panelController: panelController,
                    settings: settings,
                    character: character
                )
            )
        }

        return tools
    }
}
