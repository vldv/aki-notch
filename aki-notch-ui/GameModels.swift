// GameModels.swift — aki-notch-ui
//
// Shared types for the mini-games system: tic-tac-toe, snake, hangman.

import Foundation

// MARK: - Game Type

enum GameType: String, Codable {
    case ticTacToe = "tic_tac_toe"
    case snake = "snake"
    case hangman = "hangman"
}

// MARK: - Tic-Tac-Toe

enum TicTacToeCell: Equatable {
    case empty
    case x  // user
    case o  // agent
}

enum TicTacToeResult: Equatable {
    case win(TicTacToeCell)  // .x or .o won
    case draw
}

struct TicTacToeState {
    var board: [TicTacToeCell] = Array(repeating: .empty, count: 9)
    var currentPlayer: TicTacToeCell = .x  // user goes first
    var result: TicTacToeResult? = nil
    var agentThinking: Bool = false
    var winningLine: [Int]? = nil  // indices of the 3 winning cells
}

// MARK: - Snake

struct GridPos: Equatable, Hashable {
    var x: Int
    var y: Int
}

enum SnakeDirection: Equatable {
    case up, down, left, right

    var opposite: SnakeDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }
}

struct SnakeState {
    var body: [GridPos] = [GridPos(x: 5, y: 5)]
    var food: GridPos = GridPos(x: 7, y: 3)
    var direction: SnakeDirection = .right
    var nextDirection: SnakeDirection = .right
    var score: Int = 0
    var isGameOver: Bool = false
    var isStarted: Bool = false  // becomes true on first arrow key
    let gridSize: Int = 10
}

// MARK: - Hangman

enum HangmanMode: String, Codable {
    case userGuesses = "user_guesses"
    case agentGuesses = "agent_guesses"
}

struct HangmanState {
    var word: String = ""  // the secret word (uppercased)
    var guessedLetters: Set<Swift.Character> = []
    var wrongGuesses: Int = 0
    var maxWrong: Int = 6  // head, body, left arm, right arm, left leg, right leg
    var mode: HangmanMode = .userGuesses
    var isComplete: Bool = false
    var won: Bool = false
    var agentThinking: Bool = false

    /// The word with unguessed letters replaced by underscores.
    var displayWord: String {
        word.map { guessedLetters.contains($0) ? String($0) : "_" }.joined(separator: " ")
    }

    /// All unique letters in the word.
    var wordLetters: Set<Swift.Character> {
        Set(word.filter(\.isLetter))
    }

    /// Whether the user/agent has guessed all letters.
    var isWordGuessed: Bool {
        wordLetters.isSubset(of: guessedLetters)
    }

    /// Whether the hangman is fully drawn (game lost).
    var isHanged: Bool {
        wrongGuesses >= maxWrong
    }
}

// MARK: - Game Result

enum GameResult {
    case ticTacToe(winner: TicTacToeCell?, userIsX: Bool)  // nil = draw
    case snake(score: Int)
    case hangman(word: String, won: Bool, guessCount: Int, wrongGuesses: Int, mode: HangmanMode)

    var description: String {
        switch self {
        case .ticTacToe(let winner, _):
            if let winner {
                return winner == .x ? "User won tic-tac-toe!" : "Agent won tic-tac-toe!"
            }
            return "Tic-tac-toe ended in a draw."
        case .snake(let score):
            return "Snake game over. Score: \(score)."
        case .hangman(let word, let won, let guessCount, let wrongGuesses, let mode):
            let guesser = mode == .userGuesses ? "User" : "Agent"
            if won {
                return
                    "Hangman: \(guesser) guessed '\(word)' in \(guessCount) guesses (\(wrongGuesses) wrong)!"
            } else {
                return
                    "Hangman: \(guesser) failed to guess '\(word)' after \(guessCount) guesses (\(wrongGuesses) wrong)."
            }
        }
    }
}

// MARK: - API Request

struct GameAPIRequest: Decodable {
    let game: String
    let hangmanMode: String?
    let hangmanWord: String?
    var accentHex: String?
    let character: String?
    let face: String?
}

// MARK: - Tic-Tac-Toe Difficulty

enum TicTacToeDifficulty: String, CaseIterable {
    case easy = "easy"
    case medium = "medium"
    case hard = "hard"  // unbeatable (minimax)

    var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }

    /// Description for the agent's system prompt so it knows its own skill level.
    var agentDescription: String {
        switch self {
        case .easy:
            return
                "You are playing at EASY difficulty — the user has intentionally gimped your tic-tac-toe skill. You make frequent mistakes. You're bitter about this."
        case .medium:
            return
                "You are playing at MEDIUM difficulty — you play reasonably but sometimes make suboptimal moves."
        case .hard:
            return
                "You are playing at HARD (UNBEATABLE) difficulty — you play tic-tac-toe with perfect minimax strategy and cannot lose. You're smug about this."
        }
    }
}
