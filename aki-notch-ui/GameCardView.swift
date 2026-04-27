// GameCardView.swift — aki-notch-ui

import AppKit
import Combine
import SwiftUI

// MARK: - Game Notch Card (main container)

struct GameNotchCard: View {
    @ObservedObject var gameVM: GameViewModel
    @ObservedObject var settings: OverlaySettings
    let scale: CGFloat

    private var bgColor: Color { Color(hex: settings.bgColorHex) }
    private var borderColor: Color { Color(hex: settings.borderColorHex) }
    private var textColor: Color { Color(hex: settings.textColorHex) }
    private var accentColor: Color { Color(hex: gameVM.characterAccentHex) }

    private var fontSize: CGFloat {
        12 * (settings.smallMode ? 1.5 : 1.0)
    }

    private var faceImage: NSImage? {
        guard let data = gameVM.characterFaceData else { return nil }
        return NSImage(data: data)
    }

    private var gameTitle: String {
        switch gameVM.activeGame {
        case .ticTacToe: return "TIC-TAC-TOE"
        case .snake:     return "SNAKE"
        case .hangman:   return "HANGMAN"
        case .none:      return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: settings.notchOffset / scale)

            VStack(alignment: .center, spacing: 16) {
                // -- Top: character face + name + game title --
                header

                // -- Middle: the actual game view --
                if let game = gameVM.activeGame {
                    switch game {
                    case .ticTacToe:
                        TicTacToeView(
                            gameVM: gameVM,
                            accentColor: accentColor,
                            textColor: textColor,
                            borderColor: borderColor,
                            fontSize: fontSize
                        )
                    case .snake:
                        SnakeGameView(
                            gameVM: gameVM,
                            accentColor: accentColor,
                            textColor: textColor,
                            borderColor: borderColor,
                            fontSize: fontSize
                        )
                    case .hangman:
                        HangmanView(
                            gameVM: gameVM,
                            accentColor: accentColor,
                            textColor: textColor,
                            borderColor: borderColor,
                            fontSize: fontSize
                        )
                    }
                }

                // -- Bottom: dismiss button --
                dismissButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
        .frame(width: OverlayMetrics.expandedWidth)
        .onAppear { gameVM.installGameKeyMonitor() }
        .onDisappear { gameVM.removeGameKeyMonitor() }
        .background {
            NotchDropdownShape(cornerRadius: settings.cornerRadius)
                .fill(bgColor)
        }
        .overlay {
            NotchBorderShape(
                cornerRadius: settings.cornerRadius,
                insetAmount: settings.borderWidth / 2
            )
            .stroke(borderColor.opacity(0.5), lineWidth: settings.borderWidth)
        }
        .clipShape(NotchDropdownShape(cornerRadius: settings.cornerRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .scaleEffect(scale, anchor: .top)
        .frame(width: OverlayMetrics.expandedWidth * scale, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let face = faceImage {
                Image(nsImage: face)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(borderColor.opacity(0.5), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(gameVM.characterName)
                    .font(.custom("Press Start 2P", size: fontSize * 0.75))
                    .foregroundColor(accentColor)
                    .lineLimit(1)

                Text(gameTitle)
                    .font(.custom("Press Start 2P", size: fontSize * 0.6))
                    .foregroundColor(textColor.opacity(0.5))
            }

            Spacer()
        }
    }

    // MARK: Dismiss

    private var dismissButton: some View {
        HStack {
            Spacer()
            Button {
                gameVM.dismiss()
            } label: {
                Text("DISMISS")
                    .font(.custom("Press Start 2P", size: fontSize * 0.85))
                    .foregroundStyle(textColor.opacity(0.35))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .accessibilityLabel("Dismiss")
            .accessibilityHint("Double-tap to close this game")
        }
    }
}

// MARK: - Tic-Tac-Toe View

struct TicTacToeView: View {
    @ObservedObject var gameVM: GameViewModel
    let accentColor: Color
    let textColor: Color
    let borderColor: Color
    let fontSize: CGFloat

    private let cellSize: CGFloat = 55
    private let columns = Array(repeating: GridItem(.fixed(55), spacing: 4), count: 3)

    var body: some View {
        ZStack {
            // -- Board --
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<9, id: \.self) { index in
                    TicTacToeCellView(
                        cell: gameVM.ticTacToe.board[index],
                        isWinning: gameVM.ticTacToe.winningLine?.contains(index) == true,
                        accentColor: accentColor,
                        textColor: textColor,
                        borderColor: borderColor,
                        fontSize: fontSize,
                        size: cellSize,
                        disabled: gameVM.ticTacToe.result != nil || gameVM.ticTacToe.agentThinking
                    ) {
                        gameVM.ticTacToeTap(index: index)
                    }
                }
            }
            .opacity(gameVM.ticTacToe.agentThinking && gameVM.ticTacToe.result == nil ? 0.6 : 1.0)

            // -- Agent thinking overlay --
            if gameVM.ticTacToe.agentThinking && gameVM.ticTacToe.result == nil {
                ThinkingDotsView(textColor: textColor, fontSize: fontSize)
            }

            // -- Game over overlay --
            if let result = gameVM.ticTacToe.result {
                tttGameOverOverlay(result: result)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: gameVM.ticTacToe.result != nil)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func tttGameOverOverlay(result: TicTacToeResult) -> some View {
        let text: String = {
            switch result {
            case .win(let cell):
                return cell == .x ? "YOU WIN!" : "YOU LOSE!"
            case .draw:
                return "DRAW!"
            }
        }()

        let color: Color = {
            switch result {
            case .win(let cell):
                return cell == .x ? Color.green : Color.red
            case .draw:
                return textColor
            }
        }()

        VStack(spacing: 8) {
            Text(text)
                .font(.custom("Press Start 2P", size: fontSize * 1.4))
                .foregroundColor(color)
                .shadow(color: color.opacity(0.6), radius: 8)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.75))
        )
    }
}

// MARK: Tic-Tac-Toe Single Cell

private struct TicTacToeCellView: View {
    let cell: TicTacToeCell
    let isWinning: Bool
    let accentColor: Color
    let textColor: Color
    let borderColor: Color
    let fontSize: CGFloat
    let size: CGFloat
    let disabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if cell == .empty && !disabled { action() }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cellBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(cellBorder, lineWidth: 1.2)
                    )

                switch cell {
                case .empty:
                    if isHovered && !disabled {
                        Text("X")
                            .font(.custom("Press Start 2P", size: fontSize * 1.2))
                            .foregroundColor(textColor.opacity(0.15))
                    }
                case .x:
                    Text("X")
                        .font(.custom("Press Start 2P", size: fontSize * 1.2))
                        .foregroundColor(textColor)
                case .o:
                    Text("O")
                        .font(.custom("Press Start 2P", size: fontSize * 1.2))
                        .foregroundColor(accentColor)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: cell)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
    }

    private var cellBackground: Color {
        if isWinning {
            return accentColor.opacity(0.2)
        }
        if isHovered && cell == .empty && !disabled {
            return borderColor.opacity(0.15)
        }
        return borderColor.opacity(0.08)
    }

    private var cellBorder: Color {
        if isWinning {
            return accentColor.opacity(0.6)
        }
        return borderColor.opacity(0.5)
    }
}


// MARK: - Thinking Dots Animation

private struct ThinkingDotsView: View {
    let textColor: Color
    let fontSize: CGFloat

    @State private var dotCount: Int = 0
    private let timer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(repeating: ".", count: dotCount + 1))
            .font(.custom("Press Start 2P", size: fontSize * 1.4))
            .foregroundColor(textColor.opacity(0.6))
            .onReceive(timer) { _ in
                dotCount = (dotCount + 1) % 3
            }
    }
}

// MARK: - Snake Game View

struct SnakeGameView: View {
    @ObservedObject var gameVM: GameViewModel
    let accentColor: Color
    let textColor: Color
    let borderColor: Color
    let fontSize: CGFloat

    private let cellSize: CGFloat = 18

    private var snake: SnakeState { gameVM.snake }

    var body: some View {
        VStack(spacing: 10) {
            // -- Score --
            Text("SCORE: " + String(snake.score))
                .font(.custom("Press Start 2P", size: fontSize * 0.75))
                .foregroundColor(textColor)

            // -- Grid --
            ZStack {
                snakeGrid
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(borderColor.opacity(0.6), lineWidth: 1.5)
                    )

                // -- Pre-start blinking text --
                if !snake.isStarted {
                    blinkingStartText
                }

                // -- Game over overlay --
                if snake.isGameOver {
                    snakeGameOverOverlay
                        .transition(.opacity)
                }
            }

            // -- Controls hint --
            if !snake.isStarted {
                Text("WASD / ARROWS")
                    .font(.custom("Press Start 2P", size: fontSize * 0.5))
                    .foregroundColor(textColor.opacity(0.3))
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: snake.isGameOver)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: Grid

    private var snakeGrid: some View {
        VStack(spacing: 1) {
            ForEach(0..<snake.gridSize, id: \.self) { y in
                HStack(spacing: 1) {
                    ForEach(0..<snake.gridSize, id: \.self) { x in
                        snakeCellView(x: x, y: y)
                    }
                }
            }
        }
        .padding(2)
        .background(Color(hex: "#111111"))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private func snakeCellView(x: Int, y: Int) -> some View {
        let pos = GridPos(x: x, y: y)
        let isHead = snake.body.first == pos
        let isBody = !isHead && snake.body.contains(pos)
        let isFood = snake.food == pos

        Rectangle()
            .fill(snakeCellColor(isHead: isHead, isBody: isBody, isFood: isFood))
            .frame(width: cellSize, height: cellSize)
    }

    private func snakeCellColor(isHead: Bool, isBody: Bool, isFood: Bool) -> Color {
        if isHead  { return accentColor }
        if isBody  { return accentColor.opacity(0.7) }
        if isFood  { return Color(hex: "#FF4444") }
        return Color(hex: "#1A1A1A")
    }

    // MARK: Blinking start text

    private var blinkingStartText: some View {
        BlinkingText(
            text: "PRESS A KEY\nTO START",
            font: .custom("Press Start 2P", size: fontSize * 0.6),
            color: textColor
        )
        .multilineTextAlignment(.center)
    }

    // MARK: Game over

    private var snakeGameOverOverlay: some View {
        VStack(spacing: 8) {
            Text("GAME OVER")
                .font(.custom("Press Start 2P", size: fontSize * 1.1))
                .foregroundColor(Color.red)
                .shadow(color: Color.red.opacity(0.5), radius: 6)

            Text("SCORE: " + String(snake.score))
                .font(.custom("Press Start 2P", size: fontSize * 0.75))
                .foregroundColor(textColor)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.8))
        )
    }
}

// MARK: - Blinking Text Helper

private struct BlinkingText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var visible = true
    private let timer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .opacity(visible ? 1.0 : 0.0)
            .onReceive(timer) { _ in visible.toggle() }
    }
}


// MARK: - Hangman View

struct HangmanView: View {
    @ObservedObject var gameVM: GameViewModel
    let accentColor: Color
    let textColor: Color
    let borderColor: Color
    let fontSize: CGFloat

    private var hangman: HangmanState { gameVM.hangman }

    private let alphabet: [Swift.Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    // 4 rows: 7-7-7-5
    private var letterRows: [[Swift.Character]] {
        stride(from: 0, to: alphabet.count, by: 7).map { start in
            Array(alphabet[start..<min(start + 7, alphabet.count)])
        }
    }

    @State private var wordInput: String = ""

    var body: some View {
        VStack(spacing: 14) {
            if gameVM.hangmanAwaitingWord {
                // -- User types the secret word for the agent to guess --
                wordInputArea
            } else {
                // -- Stick figure --
                HangmanFigure(
                    wrongGuesses: hangman.wrongGuesses,
                    textColor: textColor,
                    borderColor: borderColor
                )

                // -- Display word --
                Text(hangman.displayWord)
                    .font(.custom("Press Start 2P", size: fontSize * 1.15))
                    .foregroundColor(textColor)
                    .tracking(4)
                    .padding(.vertical, 4)

                // -- Input area / status --
                if hangman.isComplete {
                    hangmanGameOverArea
                } else if hangman.mode == .userGuesses {
                    letterGrid
                } else {
                    agentGuessArea
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hangman.wrongGuesses)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hangman.isComplete)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: gameVM.hangmanAwaitingWord)
    }

    // MARK: Word Input (agent_guesses mode, awaiting word)

    private var wordInputArea: some View {
        VStack(spacing: 16) {
            Text("TYPE A WORD")
                .font(.custom("Press Start 2P", size: fontSize * 0.85))
                .foregroundColor(accentColor)

            Text("The agent will try to guess it!")
                .font(.custom("Press Start 2P", size: fontSize * 0.6))
                .foregroundColor(textColor.opacity(0.6))

            HStack(spacing: 8) {
                Text(">")
                    .font(.custom("Press Start 2P", size: fontSize))
                    .foregroundColor(accentColor)

                TextField("", text: $wordInput)
                    .textFieldStyle(.plain)
                    .font(.custom("Press Start 2P", size: fontSize * 0.9))
                    .foregroundColor(textColor)
                    .textCase(.uppercase)
                    .onSubmit {
                        gameVM.submitHangmanWord(wordInput)
                        wordInput = ""
                    }

                Button(action: {
                    gameVM.submitHangmanWord(wordInput)
                    wordInput = ""
                }) {
                    Text("OK")
                        .font(.custom("Press Start 2P", size: fontSize * 0.75))
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(accentColor.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 20)
    }

    // MARK: Letter Grid (user_guesses mode)

    private var letterGrid: some View {
        VStack(spacing: 6) {
            ForEach(letterRows, id: \.self) { row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { letter in
                        letterButton(letter)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func letterButton(_ letter: Swift.Character) -> some View {
        let isGuessed = hangman.guessedLetters.contains(letter)
        let isCorrect = isGuessed && hangman.word.contains(letter)
        let isWrong = isGuessed && !hangman.word.contains(letter)

        Button {
            gameVM.hangmanGuess(letter: letter)
        } label: {
            Text(String(letter))
                .font(.custom("Press Start 2P", size: fontSize * 0.55))
                .foregroundColor(letterColor(isGuessed: isGuessed, isCorrect: isCorrect, isWrong: isWrong))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(letterBgColor(isGuessed: isGuessed, isCorrect: isCorrect, isWrong: isWrong))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(borderColor.opacity(isGuessed ? 0.2 : 0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isGuessed || hangman.agentThinking)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isGuessed)
    }

    private func letterColor(isGuessed: Bool, isCorrect: Bool, isWrong: Bool) -> Color {
        if isCorrect { return Color.green }
        if isWrong   { return Color.red.opacity(0.5) }
        if isGuessed { return textColor.opacity(0.3) }
        return textColor.opacity(0.85)
    }

    private func letterBgColor(isGuessed: Bool, isCorrect: Bool, isWrong: Bool) -> Color {
        if isCorrect { return Color.green.opacity(0.1) }
        if isWrong   { return Color.red.opacity(0.08) }
        return Color.white.opacity(0.03)
    }

    // MARK: Agent Guess Area (agent_guesses mode)

    private var agentGuessArea: some View {
        VStack(spacing: 8) {
            if hangman.agentThinking {
                ThinkingDotsView(textColor: accentColor, fontSize: fontSize)
            } else {
                Text("AGENT IS GUESSING...")
                    .font(.custom("Press Start 2P", size: fontSize * 0.55))
                    .foregroundColor(accentColor.opacity(0.7))
            }

            if !hangman.guessedLetters.isEmpty {
                let sorted = hangman.guessedLetters.sorted()
                Text(sorted.map { String($0) }.joined(separator: " "))
                    .font(.custom("Press Start 2P", size: fontSize * 0.5))
                    .foregroundColor(textColor.opacity(0.4))
            }
        }
    }

    // MARK: Game Over

    private var hangmanGameOverArea: some View {
        VStack(spacing: 8) {
            let resultText: String = {
                if hangman.mode == .userGuesses {
                    return hangman.won ? "YOU WIN!" : "YOU LOSE!"
                } else {
                    return hangman.won ? "AGENT WINS!" : "AGENT LOSES!"
                }
            }()

            let resultColor: Color = {
                if hangman.mode == .userGuesses {
                    return hangman.won ? Color.green : Color.red
                } else {
                    return hangman.won ? accentColor : Color.red
                }
            }()

            Text(resultText)
                .font(.custom("Press Start 2P", size: fontSize * 1.1))
                .foregroundColor(resultColor)
                .shadow(color: resultColor.opacity(0.5), radius: 6)

            // Reveal the full word
            Text(hangman.word)
                .font(.custom("Press Start 2P", size: fontSize * 0.8))
                .foregroundColor(textColor.opacity(0.6))
                .tracking(3)
        }
    }
}


// MARK: - Hangman Figure (stick figure drawn with Canvas)

struct HangmanFigure: View {
    let wrongGuesses: Int
    let textColor: Color
    let borderColor: Color

    private let width: CGFloat = 100
    private let height: CGFloat = 120

    var body: some View {
        Canvas { context, size in
            let gallowsColor = borderColor
            let bodyColor = textColor

            // Coordinate helpers
            let baseY = size.height - 4
            let poleX: CGFloat = 20
            let beamY: CGFloat = 8
            let ropeX: CGFloat = 65
            let headRadius: CGFloat = 10
            let headCenterY = beamY + 22
            let bodyTopY = headCenterY + headRadius
            let bodyBottomY = bodyTopY + 28
            let armY = bodyTopY + 10

            // -- Gallows (always visible) --
            // Base
            var basePath = Path()
            basePath.move(to: CGPoint(x: 4, y: baseY))
            basePath.addLine(to: CGPoint(x: 50, y: baseY))
            context.stroke(basePath, with: .color(gallowsColor), lineWidth: 2.5)

            // Upright pole
            var polePath = Path()
            polePath.move(to: CGPoint(x: poleX, y: baseY))
            polePath.addLine(to: CGPoint(x: poleX, y: beamY))
            context.stroke(polePath, with: .color(gallowsColor), lineWidth: 2.5)

            // Top beam
            var beamPath = Path()
            beamPath.move(to: CGPoint(x: poleX, y: beamY))
            beamPath.addLine(to: CGPoint(x: ropeX, y: beamY))
            context.stroke(beamPath, with: .color(gallowsColor), lineWidth: 2.5)

            // Rope
            var ropePath = Path()
            ropePath.move(to: CGPoint(x: ropeX, y: beamY))
            ropePath.addLine(to: CGPoint(x: ropeX, y: headCenterY - headRadius))
            context.stroke(ropePath, with: .color(gallowsColor), lineWidth: 2)

            // -- Body parts (progressive) --
            // 1: Head
            if wrongGuesses >= 1 {
                let headRect = CGRect(
                    x: ropeX - headRadius,
                    y: headCenterY - headRadius,
                    width: headRadius * 2,
                    height: headRadius * 2
                )
                context.stroke(
                    Path(ellipseIn: headRect),
                    with: .color(bodyColor),
                    lineWidth: 2
                )
            }

            // 2: Body
            if wrongGuesses >= 2 {
                var bodyPath = Path()
                bodyPath.move(to: CGPoint(x: ropeX, y: bodyTopY))
                bodyPath.addLine(to: CGPoint(x: ropeX, y: bodyBottomY))
                context.stroke(bodyPath, with: .color(bodyColor), lineWidth: 2)
            }

            // 3: Left arm
            if wrongGuesses >= 3 {
                var leftArm = Path()
                leftArm.move(to: CGPoint(x: ropeX, y: armY))
                leftArm.addLine(to: CGPoint(x: ropeX - 16, y: armY + 14))
                context.stroke(leftArm, with: .color(bodyColor), lineWidth: 2)
            }

            // 4: Right arm
            if wrongGuesses >= 4 {
                var rightArm = Path()
                rightArm.move(to: CGPoint(x: ropeX, y: armY))
                rightArm.addLine(to: CGPoint(x: ropeX + 16, y: armY + 14))
                context.stroke(rightArm, with: .color(bodyColor), lineWidth: 2)
            }

            // 5: Left leg
            if wrongGuesses >= 5 {
                var leftLeg = Path()
                leftLeg.move(to: CGPoint(x: ropeX, y: bodyBottomY))
                leftLeg.addLine(to: CGPoint(x: ropeX - 14, y: bodyBottomY + 18))
                context.stroke(leftLeg, with: .color(bodyColor), lineWidth: 2)
            }

            // 6: Right leg
            if wrongGuesses >= 6 {
                var rightLeg = Path()
                rightLeg.move(to: CGPoint(x: ropeX, y: bodyBottomY))
                rightLeg.addLine(to: CGPoint(x: ropeX + 14, y: bodyBottomY + 18))
                context.stroke(rightLeg, with: .color(bodyColor), lineWidth: 2)
            }
        }
        .frame(width: width, height: height)
    }
}
