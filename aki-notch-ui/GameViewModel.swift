// GameViewModel.swift — aki-notch-ui

import AppKit
import Combine
import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.akinotch.app", category: "Games")

@MainActor
final class GameViewModel: ObservableObject {

    // MARK: - Active Game

    @Published var activeGame: GameType? = nil

    // MARK: - Character Appearance (shown on game card)

    @Published var characterName: String = ""
    @Published var characterAccentHex: String = "#7FD6FF"
    @Published var characterFaceData: Data? = nil

    // MARK: - Per-Game State

    @Published var ticTacToe = TicTacToeState()
    @Published var snake = SnakeState()
    @Published var hangman = HangmanState()
    @Published var hangmanAwaitingWord: Bool = false

    // MARK: - Snake Timer

    private var snakeTimer: Timer?
    private var gameKeyMonitor: Any?

    // MARK: - Settings reference (for difficulty)

    weak var settings: OverlaySettings?

    // MARK: - Completion

    /// Called when a game finishes. Set by AgentBrain/API before starting the game.
    var completionHandler: ((GameResult) -> Void)?

    // MARK: - Start Games

    func startTicTacToe(characterName: String, accentHex: String, faceData: Data?) {
        cleanup()
        self.characterName = characterName
        self.characterAccentHex = accentHex
        self.characterFaceData = faceData
        self.ticTacToe = TicTacToeState()
        self.activeGame = .ticTacToe
        logger.info("Started tic-tac-toe vs \(characterName)")
        LogStore.shared.info("Games", "🎮 Tic-tac-toe started vs \(characterName)")
    }

    func startSnake(characterName: String, accentHex: String, faceData: Data?) {
        cleanup()
        self.characterName = characterName
        self.characterAccentHex = accentHex
        self.characterFaceData = faceData
        self.snake = SnakeEngine.newGame()
        self.activeGame = .snake
        logger.info("Started snake game")
        LogStore.shared.info("Games", "🎮 Snake game started")
        // Timer starts on first key press (isStarted flag)
    }

    func startHangman(word: String, mode: HangmanMode, characterName: String, accentHex: String, faceData: Data?) {
        cleanup()
        self.characterName = characterName
        self.characterAccentHex = accentHex
        self.characterFaceData = faceData

        if mode == .agentGuesses && word.isEmpty {
            // Agent guesses mode with no word provided — ask user to type one
            self.hangman = HangmanEngine.newGame(word: "PLACEHOLDER", mode: mode)
            self.hangmanAwaitingWord = true
            self.activeGame = .hangman
            logger.info("Started hangman (agent_guesses) — awaiting user word")
            LogStore.shared.info("Games", "🎮 Hangman started — waiting for user\'s word")
        } else {
            // Word provided (from LLM or fallback) or user_guesses mode
            let sanitized = word.isEmpty ? HangmanEngine.wordBank.randomElement()! : word
            self.hangman = HangmanEngine.newGame(word: sanitized, mode: mode)
            self.hangmanAwaitingWord = false
            self.activeGame = .hangman
            logger.info("Started hangman (\(mode.rawValue)) — word has \(sanitized.count) letters")
            LogStore.shared.info("Games", "🎮 Hangman started (\(mode.rawValue))")

            if mode == .agentGuesses {
                startAgentHangmanLoop()
            }
        }
    }

    /// Called when the user submits their word in agent_guesses mode.
    func submitHangmanWord(_ word: String) {
        guard hangmanAwaitingWord, activeGame == .hangman else { return }
        let sanitized = word.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !sanitized.isEmpty, sanitized.allSatisfy(\.isLetter) else { return }

        hangman = HangmanEngine.newGame(word: sanitized, mode: .agentGuesses)
        hangmanAwaitingWord = false
        logger.info("User set hangman word (\(sanitized.count) letters), agent starts guessing")
        LogStore.shared.info("Games", "🎮 Hangman word set — agent guessing begins")
        startAgentHangmanLoop()
    }

    // MARK: - Tic-Tac-Toe Actions

    func ticTacToeTap(index: Int) {
        guard activeGame == .ticTacToe,
              ticTacToe.result == nil,
              ticTacToe.board[index] == .empty,
              ticTacToe.currentPlayer == .x,  // user's turn
              !ticTacToe.agentThinking
        else { return }

        // Place user's mark
        ticTacToe.board[index] = .x

        // Check if user won
        if let result = TicTacToeEngine.checkResult(board: ticTacToe.board) {
            ticTacToe.result = result
            ticTacToe.winningLine = TicTacToeEngine.winningLine(board: ticTacToe.board)
            finishGame(.ticTacToe(winner: result == .draw ? nil : .x, userIsX: true))
            return
        }

        // Agent's turn
        ticTacToe.currentPlayer = .o
        ticTacToe.agentThinking = true

        // Small delay so user sees their move before agent responds
        let difficulty = settings?.ticTacToeDifficulty ?? .hard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.activeGame == .ticTacToe else { return }

            if let move = TicTacToeEngine.bestMove(board: self.ticTacToe.board, for: .o, difficulty: difficulty) {
                self.ticTacToe.board[move] = .o
            }
            self.ticTacToe.agentThinking = false

            // Check if agent won
            if let result = TicTacToeEngine.checkResult(board: self.ticTacToe.board) {
                self.ticTacToe.result = result
                self.ticTacToe.winningLine = TicTacToeEngine.winningLine(board: self.ticTacToe.board)
                let winner: TicTacToeCell? = result == .draw ? nil : .o
                self.finishGame(.ticTacToe(winner: winner, userIsX: true))
            } else {
                self.ticTacToe.currentPlayer = .x
            }
        }
    }

    // MARK: - Snake Actions

    func snakeChangeDirection(_ direction: SnakeDirection) {
        guard activeGame == .snake, !snake.isGameOver else { return }

        let wasStarted = snake.isStarted
        snake = SnakeEngine.changeDirection(snake, to: direction)

        // Start the timer on first direction input
        if !wasStarted && snake.isStarted {
            startSnakeTimer()
        }
    }

    private func startSnakeTimer() {
        snakeTimer?.invalidate()
        snakeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.activeGame == .snake, !self.snake.isGameOver else {
                    self?.snakeTimer?.invalidate()
                    return
                }
                self.snake = SnakeEngine.tick(self.snake)
                if self.snake.isGameOver {
                    self.snakeTimer?.invalidate()
                    self.finishGame(.snake(score: self.snake.score))
                }
            }
        }
        // Use common mode so it fires even during tracking
        RunLoop.main.add(snakeTimer!, forMode: .common)
    }

    func installGameKeyMonitor() {
        guard gameKeyMonitor == nil else { return }
        gameKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Snake: arrow keys + WASD
            if self.activeGame == .snake {
                switch event.keyCode {
                case 126, 13: self.snakeChangeDirection(.up); return nil
                case 125, 1:  self.snakeChangeDirection(.down); return nil
                case 123, 0:  self.snakeChangeDirection(.left); return nil
                case 124, 2:  self.snakeChangeDirection(.right); return nil
                default: return event
                }
            }

            // Hangman (user guesses): letter keys
            if self.activeGame == .hangman,
               self.hangman.mode == .userGuesses,
               !self.hangman.isComplete,
               !self.hangmanAwaitingWord {
                if let chars = event.characters?.uppercased(), chars.count == 1,
                   let letter = chars.first, letter.isLetter {
                    self.hangmanGuess(letter: letter)
                    return nil
                }
            }

            return event
        }
    }

    func removeGameKeyMonitor() {
        if let monitor = gameKeyMonitor {
            NSEvent.removeMonitor(monitor)
            gameKeyMonitor = nil
        }
    }

    // MARK: - Hangman Actions

    func hangmanGuess(letter: Swift.Character) {
        guard activeGame == .hangman,
              !hangman.isComplete,
              hangman.mode == .userGuesses
        else { return }

        hangman = HangmanEngine.guess(letter: letter, in: hangman)

        if hangman.isComplete {
            let guessCount = hangman.guessedLetters.count
            finishGame(.hangman(word: hangman.word, won: hangman.won, guessCount: guessCount, wrongGuesses: hangman.wrongGuesses, mode: .userGuesses))
        }
    }

    private func startAgentHangmanLoop() {
        guard hangman.mode == .agentGuesses else { return }

        Task { @MainActor in
            // Small initial delay
            try? await Task.sleep(for: .seconds(1.0))

            while activeGame == .hangman && !hangman.isComplete {
                hangman.agentThinking = true
                // Thinking delay for dramatic effect
                try? await Task.sleep(for: .seconds(0.8))
                guard activeGame == .hangman else { break }

                let letter = HangmanEngine.agentGuess(state: hangman)
                hangman = HangmanEngine.guess(letter: letter, in: hangman)
                hangman.agentThinking = false

                if hangman.isComplete {
                    let guessCount = hangman.guessedLetters.count
                    finishGame(.hangman(word: hangman.word, won: hangman.won, guessCount: guessCount, wrongGuesses: hangman.wrongGuesses, mode: .agentGuesses))
                    break
                }

                // Pause between guesses
                try? await Task.sleep(for: .seconds(0.6))
            }
        }
    }

    // MARK: - Game End

    private func finishGame(_ result: GameResult) {
        logger.info("Game finished: \(result.description)")
        LogStore.shared.info("Games", "🏁 \(result.description)")

        // Don't clear activeGame yet — let the UI show the final state.
        // The completion handler is called after a short delay so the user sees the result.
        let handler = completionHandler
        completionHandler = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            handler?(result)
        }
    }

    // MARK: - Dismiss / Cleanup

    func dismiss() {
        let wasActive = activeGame
        cleanup()

        // If game was in progress, report it as dismissed
        if wasActive != nil {
            completionHandler?(
                wasActive == .snake
                    ? .snake(score: snake.score)
                    : wasActive == .ticTacToe
                        ? .ticTacToe(winner: nil, userIsX: true)
                        : .hangman(word: hangman.word, won: false, guessCount: hangman.guessedLetters.count, wrongGuesses: hangman.wrongGuesses, mode: hangman.mode)
            )
            completionHandler = nil
        }
    }

    private func cleanup() {
        snakeTimer?.invalidate()
        snakeTimer = nil
        removeGameKeyMonitor()
        activeGame = nil
        hangmanAwaitingWord = false
    }
}
