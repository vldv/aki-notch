// TicTacToeEngine.swift — aki-notch-ui

import Foundation

enum TicTacToeEngine {

    // MARK: - Winning Lines

    private static let winningLines: [[Int]] = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8],  // rows
        [0, 3, 6], [1, 4, 7], [2, 5, 8],  // columns
        [0, 4, 8], [2, 4, 6]              // diagonals
    ]

    // MARK: - Public API

    /// Returns the index (0-8) of the best move for the given player,
    /// adjusted by difficulty. Returns nil if no moves are available.
    static func bestMove(
        board: [TicTacToeCell],
        for player: TicTacToeCell,
        difficulty: TicTacToeDifficulty
    ) -> Int? {
        let available = board.indices.filter { board[$0] == .empty }
        guard !available.isEmpty else { return nil }

        let useOptimal: Bool
        switch difficulty {
        case .hard:
            useOptimal = true
        case .medium:
            useOptimal = Bool.random()          // 50% optimal
        case .easy:
            useOptimal = Int.random(in: 0..<5) == 0  // 20% optimal
        }

        guard useOptimal else {
            return available[Int.random(in: 0..<available.count)]
        }

        // Pure minimax — pick the move with the highest score for `player`.
        var bestScore = Int.min
        var bestIdx = available[0]

        for idx in available {
            var next = board
            next[idx] = player
            let score = minimax(
                board: next,
                isMaximizing: false,
                maximizingPlayer: player
            )
            if score > bestScore {
                bestScore = score
                bestIdx = idx
            }
        }

        return bestIdx
    }

    /// Checks the board and returns the result:
    /// Returns .win(.x), .win(.o), .draw, or nil if the game continues.
    static func checkResult(board: [TicTacToeCell]) -> TicTacToeResult? {
        for line in winningLines {
            let cells = line.map { board[$0] }
            if cells[0] != .empty && cells[0] == cells[1] && cells[1] == cells[2] {
                return .win(cells[0])
            }
        }

        if board.allSatisfy({ $0 != .empty }) {
            return .draw
        }

        return nil
    }

    /// Returns the three indices of the winning line, or nil if there is no winner.
    static func winningLine(board: [TicTacToeCell]) -> [Int]? {
        for line in winningLines {
            let cells = line.map { board[$0] }
            if cells[0] != .empty && cells[0] == cells[1] && cells[1] == cells[2] {
                return line
            }
        }
        return nil
    }

    // MARK: - Minimax

    /// Standard minimax with depth penalty so the AI prefers faster wins.
    /// Returns +10 − depth for maximizer win, −10 + depth for minimizer win,
    /// 0 for a draw.
    private static func minimax(
        board: [TicTacToeCell],
        isMaximizing: Bool,
        maximizingPlayer: TicTacToeCell,
        depth: Int = 0
    ) -> Int {
        let minimizingPlayer: TicTacToeCell = maximizingPlayer == .x ? .o : .x

        if let result = checkResult(board: board) {
            switch result {
            case .win(let winner):
                return winner == maximizingPlayer ? 10 - depth : -10 + depth
            case .draw:
                return 0
            }
        }

        let available = board.indices.filter { board[$0] == .empty }

        if isMaximizing {
            var best = Int.min
            for idx in available {
                var next = board
                next[idx] = maximizingPlayer
                let score = minimax(
                    board: next,
                    isMaximizing: false,
                    maximizingPlayer: maximizingPlayer,
                    depth: depth + 1
                )
                best = max(best, score)
            }
            return best
        } else {
            var best = Int.max
            for idx in available {
                var next = board
                next[idx] = minimizingPlayer
                let score = minimax(
                    board: next,
                    isMaximizing: true,
                    maximizingPlayer: maximizingPlayer,
                    depth: depth + 1
                )
                best = min(best, score)
            }
            return best
        }
    }
}
