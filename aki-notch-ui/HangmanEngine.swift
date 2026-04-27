// HangmanEngine.swift — aki-notch-ui
//
// Logic engine for the hangman mini-game. Provides game creation, letter
// guessing, frequency-based agent AI, and a built-in word bank.

import Foundation

// MARK: - HangmanEngine

enum HangmanEngine {

    // MARK: English Letter Frequency Order

    /// Letters ordered by descending frequency in English text.
    private static let frequencyOrder: [Swift.Character] = [
        "E", "T", "A", "O", "I", "N", "S", "H", "R", "D",
        "L", "C", "U", "M", "W", "F", "G", "Y", "P", "B",
        "V", "K", "J", "X", "Q", "Z",
    ]

    // MARK: - New Game

    /// Creates a fresh `HangmanState` from the given word and mode.
    /// The word is uppercased and stripped of non-letter characters.
    static func newGame(word: String, mode: HangmanMode) -> HangmanState {
        let sanitized = String(word.uppercased().filter(\.isLetter))
        return HangmanState(
            word: sanitized,
            guessedLetters: [],
            wrongGuesses: 0,
            maxWrong: 6,
            mode: mode,
            isComplete: false,
            won: false,
            agentThinking: false
        )
    }

    // MARK: - Guess

    /// Applies a letter guess to the current state and returns the updated state.
    ///
    /// - If the letter was already guessed the state is returned unchanged.
    /// - If the letter is not in the word `wrongGuesses` is incremented.
    /// - Win / lose conditions are evaluated and `isComplete` + `won` are set.
    static func guess(letter: Swift.Character, in state: HangmanState) -> HangmanState {
        let upper = Swift.Character(letter.uppercased())

        // Already guessed — no-op.
        guard !state.guessedLetters.contains(upper) else { return state }

        var next = state
        next.guessedLetters.insert(upper)

        // Wrong guess?
        if !state.wordLetters.contains(upper) {
            next.wrongGuesses += 1
        }

        // Check terminal conditions.
        if next.isWordGuessed {
            next.isComplete = true
            next.won = true
        } else if next.isHanged {
            next.isComplete = true
            next.won = false
        }

        return next
    }

    // MARK: - Agent Guess (AI)

    /// Returns the best letter for the agent to guess next.
    ///
    /// Strategy:
    /// 1. Build a set of *candidate* letters — those that appear in at least
    ///    one word position adjacent to an already-revealed letter.
    /// 2. Among those candidates, pick the one highest in frequency order.
    /// 3. Fallback: if no adjacency candidates exist (e.g. very first guess),
    ///    pick the most frequent unguessed letter overall.
    static func agentGuess(state: HangmanState) -> Swift.Character {
        let guessed = state.guessedLetters
        let wordChars = Array(state.word)

        // --- Adjacency heuristic ---
        // Find positions where the letter has already been revealed.
        var revealedIndices = Set<Int>()
        for (i, ch) in wordChars.enumerated() where guessed.contains(ch) {
            revealedIndices.insert(i)
        }

        // Collect unguessed letters that sit next to a revealed position.
        var adjacencyCandidates = Set<Swift.Character>()
        for idx in revealedIndices {
            // Check left neighbor.
            if idx > 0 {
                let left = wordChars[idx - 1]
                if left.isLetter && !guessed.contains(left) {
                    adjacencyCandidates.insert(left)
                }
            }
            // Check right neighbor.
            if idx < wordChars.count - 1 {
                let right = wordChars[idx + 1]
                if right.isLetter && !guessed.contains(right) {
                    adjacencyCandidates.insert(right)
                }
            }
        }

        // Pick the most frequent adjacency candidate.
        if !adjacencyCandidates.isEmpty {
            for letter in frequencyOrder where adjacencyCandidates.contains(letter) {
                return letter
            }
        }

        // --- Fallback: most frequent unguessed letter overall ---
        for letter in frequencyOrder where !guessed.contains(letter) {
            return letter
        }

        // Absolute fallback (should never happen in a normal game).
        return "A"
    }

    // MARK: - Word Bank

    /// ~100 interesting English words (5—10 letters) across tech, nature,
    /// animals, food, and general categories. Used when the LLM does not
    /// provide a word.
    static let wordBank: [String] = [
        // Tech
        "SWIFT",
        "PYTHON",
        "KOTLIN",
        "BINARY",
        "CURSOR",
        "DOCKER",
        "GITHUB",
        "KERNEL",
        "LAPTOP",
        "MODEM",
        "PIXEL",
        "REACT",
        "REDIS",
        "ROUTER",
        "SCALA",
        "SERVER",
        "SOCKET",
        "SYNTAX",
        "TENSOR",
        "TOKEN",
        "WIDGET",
        "XCODE",
        "CIPHER",
        "STREAM",
        "DEPLOY",
        // Nature
        "AURORA",
        "CANYON",
        "CORAL",
        "DESERT",
        "FJORD",
        "FOREST",
        "GALAXY",
        "GLACIER",
        "ISLAND",
        "JUNGLE",
        "MEADOW",
        "NEBULA",
        "OCEAN",
        "PEBBLE",
        "QUARTZ",
        "SUNSET",
        "TUNDRA",
        "VALLEY",
        "VOLCANO",
        "ZENITH",
        "BREEZE",
        "THUNDER",
        "ECLIPSE",
        "CRYSTAL",
        "COMET",
        // Animals
        "BADGER",
        "CONDOR",
        "DOLPHIN",
        "FALCON",
        "GOPHER",
        "JAGUAR",
        "KOALA",
        "LEMUR",
        "MANTIS",
        "NARWHAL",
        "OSPREY",
        "PARROT",
        "RAVEN",
        "SALMON",
        "TOUCAN",
        "TURTLE",
        "WALRUS",
        "FERRET",
        "OTTER",
        "BISON",
        "COYOTE",
        "HERON",
        "PUFFIN",
        "SQUID",
        "IGUANA",
        // Food
        "BISCUIT",
        "CHERRY",
        "COBBLER",
        "WAFFLE",
        "GINGER",
        "MANGO",
        "NOODLE",
        "PASTRY",
        "PEPPER",
        "PRETZEL",
        "QUINOA",
        "SORBET",
        "TRUFFLE",
        "TURNIP",
        "ALMOND",
        "MUFFIN",
        "PAPAYA",
        "CASHEW",
        "RADISH",
        "THYME",
        // General / Fun
        "ANCHOR",
        "PUZZLE",
        "COSMIC",
        "FLIGHT",
        "GROOVE",
        "KNIGHT",
        "LEGEND",
        "MYSTIC",
        "PIRATE",
        "QUANTUM",
        "RIDDLE",
        "SHADOW",
        "SPIRIT",
        "VOYAGE",
        "WIZARD",
        "ZEPHYR",
        "BLITZ",
        "SPARK",
        "THRONE",
        "VORTEX",
    ]
}
