// NotchOverlayViewModel.swift — aki-notch-ui

import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchOverlayViewModel: ObservableObject {
    @Published private(set) var currentCard: OverlayCard?
    @Published private(set) var isExpanded = false
    private var collapseTask: Task<Void, Never>?
    private var pendingDuration: TimeInterval = 0

    /// Continuation for tools waiting for the overlay sequence to finish.
    /// Set by overlay tools, resumed by `sequenceDidComplete()`.
    var overlaySequenceContinuation: CheckedContinuation<Void, Never>?

    /// Streaming overlay message — grows as the LLM streams characters.
    /// When non-nil, NotchCard's typewriter reads from this instead of card.message.
    /// Set to "" when streaming starts (face detected), updated with deltas,
    /// set to nil when streaming ends and tool execution takes over.
    @Published var streamingOverlayMessage: String?

    // Chat state
    @Published private(set) var chatCard: OverlayCard?
    @Published private(set) var chatProposedAnswers: [String] = []
    @Published private(set) var isChatActive = false
    private var chatResponseHandler: ((String) -> Void)?

    // Compose state
    @Published private(set) var isComposeActive = false
    @Published private(set) var composeCharacterName: String = ""
    private var composeHandlers: [(String) -> Void] = []

    // Minimize state — hides the card behind the notch, showing only a small expand triangle.
    @Published var isMinimized = false

    // Game state
    @Published private(set) var isGameActive = false
    @Published var gameViewModel: GameViewModel?

    // Interactive card height — reported by ContentView via PreferenceKey,
    // used by the panel controller to size the panel to match visible content.
    @Published var interactiveCardHeight: CGFloat = 0

    // Image side channels — populated by submitChatAnswer / submitCompose,
    // read by AgentBrain after the answer is delivered.
    var lastChatImages: [Data] = []
    private(set) var lastComposeImages: [Data] = []

    /// Conversation dismiss — set by ConversationEngine, called on DISMISS.
    var conversationDismissHandler: (() -> Void)?

    /// Message router — set by AppDelegate to route compose messages through AgentBrain.
    var messageRouter: ((String, [Data]) -> Void)?

    func apply(
        _ request: OverlayAPIRequest, appearanceDuration: TimeInterval, imagePosition: CGFloat = 0.5
    ) {
        cancelPendingChat()
        cancelCompose()
        cancelGame()
        isMinimized = false

        let resolvedName = request.name ?? request.title ?? ""
        let nameColorHex = request.nameColor ?? request.accentHex

        let decodedImageData = request.imageBase64.flatMap { Data(base64Encoded: $0) }

        // Set card data WITHOUT animation so internal layout doesn't jitter
        currentCard = OverlayCard(
            name: resolvedName,
            nameColor: nameColorHex.map { Color(hex: $0) } ?? Color(hex: "#E8E8E8"),
            message: request.message,
            imageURL: request.imageURL.flatMap(URL.init(string:)),
            image: decodedImageData.flatMap(NSImage.init(data:)),
            imageData: decodedImageData,
            accentColor: Color(hex: request.accentHex ?? "#7FD6FF"),
            imagePosition: imagePosition
        )

        // Only animate the expand toggle — this drives the slide transition
        withAnimation(.easeOut(duration: 0.45)) {
            isExpanded = request.expanded ?? true
        }

        // Duration countdown starts only after the reveal sequence finishes;
        // the card view calls sequenceDidComplete() when ready.
        pendingDuration = appearanceDuration
    }

    func showStartupCard(settings: OverlaySettings) {
        let testImage = NSImage(named: "TestImage")

        currentCard = OverlayCard(
            name: settings.startupName,
            nameColor: Color(hex: settings.startupNameColorHex),
            message: settings.startupMessage,
            imageURL: nil,
            image: testImage,
            imageData: nil,
            accentColor: Color(hex: settings.startupNameColorHex)
        )

        withAnimation(.easeOut(duration: 0.45)) {
            isExpanded = true
        }
        pendingDuration = settings.appearanceDuration
    }

    func showTestChat(settings: OverlaySettings, responseHandler: @escaping (String) -> Void) {
        // Dismiss any existing overlay
        collapseTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) {
            isExpanded = false
        }
        currentCard = nil
        cancelPendingChat()
        isMinimized = false

        let testImage = NSImage(named: "TestImage")

        chatCard = OverlayCard(
            name: settings.testName,
            nameColor: Color(hex: settings.testNameColorHex),
            message: settings.testMessage,
            imageURL: nil,
            image: testImage,
            imageData: nil,
            accentColor: Color(hex: settings.testNameColorHex)
        )
        chatProposedAnswers = ["Yes", "No", "Maybe"]
        chatResponseHandler = responseHandler

        withAnimation(.easeOut(duration: 0.45)) {
            isChatActive = true
        }
    }

    func showTestCard(appearanceDuration: TimeInterval, settings: OverlaySettings) {
        let testImage = NSImage(named: "TestImage")

        currentCard = OverlayCard(
            name: settings.testName,
            nameColor: Color(hex: settings.testNameColorHex),
            message: settings.testMessage,
            imageURL: nil,
            image: testImage,
            imageData: nil,
            accentColor: Color(hex: settings.testNameColorHex)
        )

        withAnimation(.easeOut(duration: 0.45)) {
            isExpanded = true
        }
        pendingDuration = appearanceDuration
    }

    /// Called by the card view once the intro animation (image reveal + typewriter) is done.
    func sequenceDidComplete() {
        // Resume any tool waiting for the sequence to finish.
        overlaySequenceContinuation?.resume()
        overlaySequenceContinuation = nil

        scheduleCollapse(after: pendingDuration)
    }

    func collapse() {
        collapseTask?.cancel()

        overlaySequenceContinuation?.resume()
        overlaySequenceContinuation = nil

        // If a conversation is running, cancel it instead of just collapsing.
        if let handler = conversationDismissHandler {
            conversationDismissHandler = nil
            handler()
            return
        }

        withAnimation(.easeIn(duration: 0.35)) {
            isExpanded = false
        }
    }

    /// Collapse the card without triggering the conversation dismiss handler.
    /// Used by ConversationEngine to animate between turns.
    func collapseCard() {
        collapseTask?.cancel()
        overlaySequenceContinuation?.resume()
        overlaySequenceContinuation = nil
        withAnimation(.easeIn(duration: 0.35)) {
            isExpanded = false
        }
    }

    func clear() {
        collapseTask?.cancel()
        overlaySequenceContinuation?.resume()
        overlaySequenceContinuation = nil
        cancelPendingChat()
        cancelCompose()
        cancelGame()
        isMinimized = false
        withAnimation(.easeIn(duration: 0.35)) {
            isExpanded = false
            currentCard = nil
        }
    }

    // MARK: Minimize

    func toggleMinimize() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            isMinimized.toggle()
        }
    }

    // MARK: Chat

    func applyChat(_ request: ChatAPIRequest, responseHandler: @escaping (String) -> Void) {
        // Dismiss any existing overlay
        collapseTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) {
            isExpanded = false
        }
        currentCard = nil
        isMinimized = false

        // Cancel any previous pending chat
        cancelPendingChat()
        cancelGame()

        let resolvedName = request.name ?? request.title ?? ""
        let nameColorHex = request.nameColor ?? request.accentHex

        let decodedImageData = request.imageBase64.flatMap { Data(base64Encoded: $0) }

        chatCard = OverlayCard(
            name: resolvedName,
            nameColor: nameColorHex.map { Color(hex: $0) } ?? Color(hex: "#E8E8E8"),
            message: request.message,
            imageURL: request.imageURL.flatMap(URL.init(string:)),
            image: decodedImageData.flatMap(NSImage.init(data:)),
            imageData: decodedImageData,
            accentColor: Color(hex: request.accentHex ?? "#7FD6FF")
        )
        chatProposedAnswers = request.proposedAnswers ?? []
        chatResponseHandler = responseHandler

        withAnimation(.easeOut(duration: 0.45)) {
            isChatActive = true
        }
    }

    func submitChatAnswer(_ answer: String, images: [Data] = []) {
        lastChatImages = images
        let handler = chatResponseHandler
        chatResponseHandler = nil

        // Call handler first — it may set up a follow-up chat immediately.
        handler?(answer)

        // If a follow-up was started, chatResponseHandler is non-nil again — leave state alone.
        if chatResponseHandler != nil { return }

        isMinimized = false

        withAnimation(.easeIn(duration: 0.35)) {
            isChatActive = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Guard: a new chat may have been started in the meantime.
            guard self.chatResponseHandler == nil else { return }
            self.chatCard = nil
            self.chatProposedAnswers = []
        }
    }

    /// Silently cancel an in-flight chat, responding with an empty answer.
    private func cancelPendingChat() {
        guard let handler = chatResponseHandler else { return }
        chatResponseHandler = nil
        lastChatImages = []
        isChatActive = false
        isMinimized = false
        chatCard = nil
        chatProposedAnswers = []
        handler("")
    }

    // MARK: Compose

    func openCompose(responseHandler: ((String) -> Void)? = nil, characterName: String = "") {
        // Dismiss overlay & chat
        composeCharacterName = characterName
        collapseTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) {
            isExpanded = false
        }
        currentCard = nil
        cancelPendingChat()
        isMinimized = false

        if let handler = responseHandler {
            composeHandlers.append(handler)
        }

        guard !isComposeActive else { return }

        withAnimation(.easeOut(duration: 0.45)) {
            isComposeActive = true
        }
    }

    /// Register a listener without showing the compose card.
    /// The handler fires next time the user submits via compose.
    func addComposeListener(_ handler: @escaping (String) -> Void) {
        composeHandlers.append(handler)
    }

    func submitCompose(_ message: String, images: [Data] = []) {
        lastComposeImages = images
        let handlers = composeHandlers
        composeHandlers = []

        isMinimized = false

        withAnimation(.easeIn(duration: 0.35)) {
            isComposeActive = false
        }

        composeCharacterName = ""

        // Route through messageRouter (AgentBrain) if available, otherwise fall back to postToTalk
        if let router = messageRouter {
            router(message, images)
        }

        for handler in handlers {
            handler(message)
        }
    }

    static func postToTalk(message: String, images: [Data] = [], endpoint: String) {
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = ["message": message]
        if !images.isEmpty {
            payload["images"] = images.map { $0.base64EncodedString() }
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                print("[Compose] POST \(endpoint) failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    LogStore.shared.warning(
                        "Compose", "POST \(endpoint) failed: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    func cancelCompose() {
        let handlers = composeHandlers
        composeHandlers = []
        isComposeActive = false
        isMinimized = false
        composeCharacterName = ""
        lastComposeImages = []
        for handler in handlers {
            handler("")
        }
    }

    // MARK: Game

    func startGame(gameVM: GameViewModel) {
        // Dismiss overlay & chat & compose
        collapseTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) {
            isExpanded = false
        }
        currentCard = nil
        cancelPendingChat()
        cancelCompose()
        isMinimized = false

        gameViewModel = gameVM
        withAnimation(.easeOut(duration: 0.45)) {
            isGameActive = true
        }
    }

    func endGame() {
        withAnimation(.easeIn(duration: 0.35)) {
            isGameActive = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isGameActive else { return }
            self.gameViewModel = nil
        }
    }

    private func cancelGame() {
        guard isGameActive else { return }
        gameViewModel?.dismiss()
        isGameActive = false
        gameViewModel = nil
    }

    private func scheduleCollapse(after duration: TimeInterval) {
        collapseTask?.cancel()
        guard duration > 0 else { return }

        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }
}
