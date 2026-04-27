// SnakeEngine.swift — aki-notch-ui

import Foundation

enum SnakeEngine {

    // MARK: - New Game

    static func newGame() -> SnakeState {
        let body = [
            GridPos(x: 5, y: 5),
            GridPos(x: 4, y: 5),
            GridPos(x: 3, y: 5)
        ]
        var state = SnakeState(
            body: body,
            food: GridPos(x: 0, y: 0),
            direction: .right,
            nextDirection: .right,
            score: 0,
            isGameOver: false,
            isStarted: false
        )
        state.food = spawnFood(state: state)
        return state
    }

    // MARK: - Tick

    static func tick(_ state: SnakeState) -> SnakeState {
        guard !state.isGameOver else { return state }

        var state = state

        // Apply buffered direction
        state.direction = state.nextDirection

        // Compute new head position
        let head = state.body[0]
        let newHead: GridPos
        switch state.direction {
        case .up:
            newHead = GridPos(x: head.x, y: head.y - 1)
        case .down:
            newHead = GridPos(x: head.x, y: head.y + 1)
        case .left:
            newHead = GridPos(x: head.x - 1, y: head.y)
        case .right:
            newHead = GridPos(x: head.x + 1, y: head.y)
        }

        // Wall collision
        if newHead.x < 0 || newHead.x >= state.gridSize ||
           newHead.y < 0 || newHead.y >= state.gridSize {
            state.isGameOver = true
            return state
        }

        // Self collision
        if state.body.contains(newHead) {
            state.isGameOver = true
            return state
        }

        // Insert new head
        state.body.insert(newHead, at: 0)

        // Food collision — grow
        if newHead == state.food {
            state.score += 1
            state.food = spawnFood(state: state)
        } else {
            // Normal move — remove tail
            state.body.removeLast()
        }

        return state
    }

    // MARK: - Change Direction

    static func changeDirection(_ state: SnakeState, to newDirection: SnakeDirection) -> SnakeState {
        // Prevent reversing into yourself
        guard newDirection != state.direction.opposite else { return state }

        var state = state
        state.nextDirection = newDirection
        if !state.isStarted {
            state.isStarted = true
        }
        return state
    }

    // MARK: - Spawn Food (private)

    private static func spawnFood(state: SnakeState) -> GridPos {
        let occupied = Set(state.body)
        var candidate: GridPos
        repeat {
            candidate = GridPos(
                x: Int.random(in: 0..<state.gridSize),
                y: Int.random(in: 0..<state.gridSize)
            )
        } while occupied.contains(candidate)
        return candidate
    }
}
