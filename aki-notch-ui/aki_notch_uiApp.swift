//
//  aki_notch_uiApp.swift
//  aki-notch-ui
//
//  Created by Victor on 26/03/2026.
//

import AppKit
import Carbon
import Combine
import CoreText
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }()
    private let viewModel = NotchOverlayViewModel()
    let settings = OverlaySettings()
    let licenseManager = LicenseManager()
    private var panelController: NotchPanelController?
    private var settingsWindowController: NSWindowController?
    private var activationWindowController: NSWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var statusBarController: StatusBarController?
    private var onboardingWindowController: NSWindowController?
    private var presenceObservers: [Any] = []
    private var interactionObservers: [AnyCancellable] = []
    private(set) var updaterReady = false

    // Agent system
    let characterStore = CharacterStore()
    let providerStore = ProviderStore()
    private var agentBrain: AgentBrain?
    private let triggerEngine = TriggerEngine()
    private var conversationEngine: ConversationEngine?
    private let gameViewModel = GameViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Register bundled pixel font
        if let fontURL = Bundle.main.url(forResource: "PressStart2P-vaV7", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }

        // Set initial activation policy based on saved preference
        updateDockIconVisibility()

        // Detect built-in display for lid-closed suppression
        DisplayStateMonitor.setup()

        // Start Sparkle updater (deferred from init to avoid Info.plist race)
        do {
            try updaterController.updater.start()
            updaterReady = true
        } catch {
            print("[Sparkle] Failed to start updater: \(error.localizedDescription)")
            LogStore.shared.error(
                "Sparkle", "Failed to start updater: \(error.localizedDescription)")
        }

        let panelController = NotchPanelController(viewModel: viewModel, settings: settings)
        panelController.show()
        self.panelController = panelController

        do {
            try LocalOverlayAPIServer.shared.start(
                port: UInt16(settings.apiPort),
                onOverlay: { [weak self] request in
                    guard let self else { return }
                    if DisplayStateMonitor.isLidClosed() {
                        LogStore.shared.info("API", "Suppressed overlay — lid closed")
                        return
                    }
                    var enriched = request
                    if let charName = request.character,
                        let resolved = self.resolveCharacter(name: charName, face: request.face)
                    {
                        if enriched.name == nil { enriched.name = resolved.name }
                        if enriched.nameColor == nil { enriched.nameColor = resolved.accentHex }
                        if enriched.accentHex == nil { enriched.accentHex = resolved.accentHex }
                        if enriched.imageBase64 == nil {
                            enriched.imageBase64 = resolved.imageBase64
                        }
                    }
                    self.viewModel.apply(
                        enriched, appearanceDuration: self.settings.appearanceDuration)
                    self.panelController?.show()
                    if let name = enriched.name, !enriched.message.isEmpty {
                        HistoryStore.shared.recordCharacterMessage(
                            characterName: name,
                            accentColorHex: enriched.accentHex ?? "#7FD6FF",
                            message: enriched.message
                        )
                    }
                },
                onCollapse: { [weak self] in
                    self?.viewModel.collapse()
                    self?.panelController?.disableInteraction()
                },
                onClear: { [weak self] in
                    self?.viewModel.clear()
                    self?.panelController?.disableInteraction()
                },
                onChat: { [weak self] request, responseHandler in
                    guard let self else { return }
                    if DisplayStateMonitor.isLidClosed() {
                        LogStore.shared.info("API", "Auto-dismissed chat — lid closed")
                        responseHandler("")
                        return
                    }
                    var enriched = request
                    if let charName = request.character,
                        let resolved = self.resolveCharacter(name: charName, face: request.face)
                    {
                        if enriched.name == nil { enriched.name = resolved.name }
                        if enriched.nameColor == nil { enriched.nameColor = resolved.accentHex }
                        if enriched.accentHex == nil { enriched.accentHex = resolved.accentHex }
                        if enriched.imageBase64 == nil {
                            enriched.imageBase64 = resolved.imageBase64
                        }
                    }
                    if let name = enriched.name, !enriched.message.isEmpty {
                        HistoryStore.shared.recordCharacterMessage(
                            characterName: name,
                            accentColorHex: enriched.accentHex ?? "#7FD6FF",
                            message: enriched.message
                        )
                    }
                    self.viewModel.applyChat(enriched) { [weak self] answer in
                        self?.panelController?.disableInteraction()
                        if !answer.isEmpty {
                            HistoryStore.shared.recordUserMessage(message: answer)
                        }
                        responseHandler(answer)
                    }
                    self.panelController?.show()
                    self.panelController?.enableInteraction(
                        smallMode: self.settings.smallMode,
                        contentHeight: self.viewModel.interactiveCardHeight
                    )
                },
                onListen: { [weak self] responseHandler in
                    guard let self else { return }
                    self.viewModel.addComposeListener { [weak self] message in
                        self?.panelController?.disableInteraction()
                        responseHandler(message)
                    }
                },
                onGame: { [weak self] request, responseHandler in
                    guard let self else { return }
                    guard let gameType = GameType(rawValue: request.game) else {
                        responseHandler("Error: unknown game '\(request.game)'")
                        return
                    }
                    if DisplayStateMonitor.isLidClosed() {
                        LogStore.shared.info("API", "Suppressed game — lid closed")
                        responseHandler("Error: lid closed")
                        return
                    }

                    var enriched = request
                    var resolvedFaceData: Data? = nil
                    if let charName = request.character,
                        let resolved = self.resolveCharacter(name: charName, face: request.face)
                    {
                        if enriched.accentHex == nil { enriched.accentHex = resolved.accentHex }
                        if let b64 = resolved.imageBase64, let data = Data(base64Encoded: b64) {
                            resolvedFaceData = data
                        }
                    }

                    self.gameViewModel.completionHandler = { [weak self] result in
                        responseHandler(result.description)
                        self?.viewModel.endGame()
                        self?.panelController?.disableInteraction()
                    }

                    switch gameType {
                    case .ticTacToe:
                        self.gameViewModel.startTicTacToe(
                            characterName: enriched.character ?? enriched.accentHex ?? "Game",
                            accentHex: enriched.accentHex ?? "#7FD6FF",
                            faceData: resolvedFaceData
                        )
                    case .snake:
                        self.gameViewModel.startSnake(
                            characterName: enriched.character ?? "Snake",
                            accentHex: enriched.accentHex ?? "#4ADE80",
                            faceData: resolvedFaceData
                        )
                    case .hangman:
                        let mode =
                            HangmanMode(rawValue: enriched.hangmanMode ?? "user_guesses")
                            ?? .userGuesses
                        self.gameViewModel.startHangman(
                            word: enriched.hangmanWord ?? "",
                            mode: mode,
                            characterName: enriched.character ?? "Hangman",
                            accentHex: enriched.accentHex ?? "#FBBF24",
                            faceData: resolvedFaceData
                        )
                    }

                    self.viewModel.startGame(gameVM: self.gameViewModel)
                    self.panelController?.show()
                    self.panelController?.enableInteraction(
                        smallMode: self.settings.smallMode,
                        contentHeight: self.viewModel.interactiveCardHeight
                    )
                },
                onCharacters: { [weak self] in
                    guard let self else { return [] }
                    return self.characterStore.characters.map { char in
                        [
                            "name": char.name,
                            "accent_hex": char.accentHex,
                            "faces": char.faceNames,
                        ] as [String: Any]
                    }
                }
            )
        } catch {
            print("[API Server] Failed to start: \(error.localizedDescription)")
            LogStore.shared.error(
                "API Server", "Failed to start: \(error.localizedDescription)")
        }

        // Register global hotkey ⌘⇧K via Carbon
        registerHotKey()

        // Set up status bar icon
        setupStatusBar()

        // Observe app presence setting changes
        observePresenceSettings()

        // Safety net: auto-disable interaction when no interactive card is showing
        observeInteractionState()

        // Re-assert panel state after sleep/wake
        observeSleepWake()

        // Show onboarding on first launch, otherwise proceed normally
        if !settings.hasCompletedOnboarding {
            showOnboarding()
        } else {
            finishLaunch()
        }

        // If trial expired and no license, show activation window
        if !licenseManager.isLicensed && settings.hasCompletedOnboarding {
            showActivationWindow()
        }

        // Listen for test-character triggers from the settings UI (always registered)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTestCharacterTrigger(_:)),
            name: .testCharacterTrigger,
            object: nil
        )

        // Listen for test-conversation triggers from the settings UI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTestConversationTrigger(_:)),
            name: .testConversationTrigger,
            object: nil
        )
    }

    // MARK: - Onboarding

    // MARK: - Activation Window

    @objc func showActivationWindow() {
        if let window = activationWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let activationView = ActivationView(
            licenseManager: licenseManager,
            onDismiss: { [weak self] in
                self?.activationWindowController?.close()
                self?.activationWindowController = nil
            }
        )

        let hostingController = NSHostingController(rootView: activationView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Aki Notch — License"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 400, height: 300))
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.activationWindowController = controller
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView(
            onComplete: { [weak self] in
                guard let self else { return }
                self.settings.hasCompletedOnboarding = true
                self.onboardingWindowController?.close()
                self.onboardingWindowController = nil
                self.finishLaunch()
            },
            onAPIKeyProvided: { [weak self] apiKey in
                guard let self else { return }
                // Find the seeded Anthropic provider and set its key
                if let anthropic = self.providerStore.providers.first(where: {
                    $0.providerType == .anthropic
                }) {
                    anthropic.setApiKey(apiKey)
                }
            },
            onOpenSettings: { [weak self] in
                self?.showSettingsWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        )

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Aki Notch"
        window.styleMask = [.titled]
        window.setContentSize(NSSize(width: 480, height: 400))
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.onboardingWindowController = controller
    }

    /// Called after onboarding completes (or immediately if already onboarded).
    private func finishLaunch() {
        // Wire compose messages through routeUserMessage (AgentBrain → fallback to /talk)
        viewModel.messageRouter = { [weak self] message, images in
            self?.routeUserMessage(message, images: images)
        }

        // Wire game view model settings reference
        gameViewModel.settings = settings

        // Fire startup card if enabled (only when no character has startup greeting)
        let anyCharacterStartup = characterStore.characters.contains { char in
            let config = CharacterTriggerConfig.load(from: char.directoryURL)
            return config.enabled && config.startupGreeting
        }
        if settings.startupEnabled && !anyCharacterStartup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.viewModel.showStartupCard(settings: self.settings)
                self.panelController?.show()
            }
        }

        // Start built-in agents if enabled
        startAgentsIfEnabled(isInitialLaunch: true)
    }

    @objc private func handleTestCharacterTrigger(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
            let character = userInfo["character"] as? Character,
            let context = userInfo["context"] as? String
        else { return }

        guard let brain = agentBrain else {
            // If agents aren't running yet, spin up a temporary brain for the test
            guard let panel = panelController else { return }
            let tempBrain = AgentBrain(
                providerStore: providerStore,
                viewModel: viewModel,
                panelController: panel,
                settings: settings
            )
            Task {
                await tempBrain.think(character: character, triggerContext: context)
            }
            return
        }

        Task {
            await brain.think(character: character, triggerContext: context)
        }
    }

    @objc private func handleTestConversationTrigger(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
            let participants = userInfo["participants"] as? [Character],
            let context = userInfo["context"] as? String,
            let maxTurns = userInfo["maxTurns"] as? Int,
            let pauseBetweenTurns = userInfo["pauseBetweenTurns"] as? Double
        else { return }

        guard participants.count >= 2 else { return }

        guard let engine = conversationEngine else {
            // If agents aren't running yet, spin up a temporary engine for the test
            guard let panel = panelController else { return }
            let tempEngine = ConversationEngine(
                providerStore: providerStore,
                viewModel: viewModel,
                panelController: panel,
                settings: settings
            )
            tempEngine.startConversation(
                participants: participants,
                context: context,
                maxTurns: maxTurns,
                pauseBetweenTurns: pauseBetweenTurns
            )
            return
        }

        engine.startConversation(
            participants: participants,
            context: context,
            maxTurns: maxTurns,
            pauseBetweenTurns: pauseBetweenTurns
        )
    }

    // MARK: - Agent System

    func startAgentsIfEnabled(isInitialLaunch: Bool = false) {
        // Stop any existing triggers
        triggerEngine.stop()
        agentBrain = nil
        conversationEngine = nil

        guard let panel = panelController else { return }

        let brain = AgentBrain(
            providerStore: providerStore,
            viewModel: viewModel,
            panelController: panel,
            settings: settings
        )
        self.agentBrain = brain

        let convoEngine = ConversationEngine(
            providerStore: providerStore,
            viewModel: viewModel,
            panelController: panel,
            settings: settings
        )
        self.conversationEngine = convoEngine
        brain.conversationEngine = convoEngine
        brain.gameViewModel = gameViewModel
        convoEngine.gameViewModel = gameViewModel

        // Build trigger configs per character (only enabled ones)
        var pairs: [(character: Character, config: CharacterTriggerConfig)] = []
        for character in characterStore.characters {
            let config = CharacterTriggerConfig.load(from: character.directoryURL)
            guard config.enabled else { continue }
            pairs.append((character: character, config: config))
        }

        // Only spin up the brain if there are enabled characters
        guard !pairs.isEmpty else { return }

        // Start triggers
        triggerEngine.start(
            characters: pairs,
            settings: settings,
            characterStore: characterStore,
            callback: { [weak brain] character, context in
                await brain?.think(character: character, triggerContext: context)
            },
            conversationCallback: { [weak convoEngine] participants, context, maxTurns, pause in
                convoEngine?.startConversation(
                    participants: participants,
                    context: context,
                    maxTurns: maxTurns,
                    pauseBetweenTurns: pause
                )
            }
        )

        // Fire startup greetings only on actual app launch, not on settings changes
        if isInitialLaunch {
            triggerEngine.fireStartupGreetings(characters: pairs)
        }
    }

    private func registerHotKey() {
        // Install a Carbon event handler for hot-key pressed events
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let handlerRef = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.openCompose()
                }
                return noErr
            },
            1,
            &eventType,
            handlerRef,
            nil
        )

        // ⌘⇧K — keycode 0x28 is 'k'
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x414B_4931),  // "AKI1"
            id: 1)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_K), modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        let controller = StatusBarController()
        controller.settings = settings

        controller.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        controller.isUpdaterAvailable = updaterReady
        controller.onCheckForUpdates = { [weak self] in
            guard let self, self.updaterReady else { return }
            self.updaterController.checkForUpdates(nil)
        }
        controller.onActivateLicense = { [weak self] in
            self?.showActivationWindow()
        }
        controller.licenseManager = licenseManager
        controller.onCompose = { [weak self] in
            self?.openCompose()
        }
        controller.onTestPayload = { [weak self] in
            guard let self else { return }
            self.viewModel.showTestCard(
                appearanceDuration: self.settings.appearanceDuration, settings: self.settings)
            self.panelController?.show()
        }
        controller.onTestChat = { [weak self] in
            self?.sendTestChat()
        }
        controller.onTestConversation = { [weak self] in
            self?.sendTestConversation()
        }
        controller.isTestConversationEnabled = { [weak self] in
            (self?.characterStore.characters.count ?? 0) >= 2
        }
        controller.onToggleSmallMode = { [weak self] in
            self?.settings.smallMode.toggle()
        }
        controller.onToggleDockIcon = { [weak self] in
            guard let self else { return }
            let newValue = !self.settings.showDockIcon
            // Guard: at least one must stay on
            if !newValue && !self.settings.showStatusBarIcon {
                self.settings.showStatusBarIcon = true
            }
            self.settings.showDockIcon = newValue
        }
        controller.onToggleStatusBar = { [weak self] in
            guard let self else { return }
            let newValue = !self.settings.showStatusBarIcon
            // Guard: at least one must stay on
            if !newValue && !self.settings.showDockIcon {
                self.settings.showDockIcon = true
            }
            self.settings.showStatusBarIcon = newValue
        }

        if settings.showStatusBarIcon {
            controller.show()
        }

        self.statusBarController = controller
    }

    private func updateDockIconVisibility() {
        let policy: NSApplication.ActivationPolicy = settings.showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
        if policy == .accessory {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func observePresenceSettings() {
        let dockObserver = settings.$showDockIcon.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateDockIconVisibility()
            }
        }
        let statusBarObserver = settings.$showStatusBarIcon.sink { [weak self] newValue in
            DispatchQueue.main.async {
                if newValue {
                    self?.statusBarController?.show()
                } else {
                    self?.statusBarController?.hide()
                }
            }
        }
        presenceObservers = [dockObserver, statusBarObserver]
    }

    /// Safety net: when all interactive states become false, ensure the panel
    /// returns to pass-through mode. This catches edge cases where the direct
    /// disableInteraction() call is missed (e.g. compose submit without /listen
    /// handlers).
    private func observeInteractionState() {
        let interactionObserver = Publishers.CombineLatest(
            viewModel.$isComposeActive,
            viewModel.$isChatActive
        )
        .dropFirst()  // skip the initial (false, false) emission
        .sink { [weak self] isCompose, isChat in
            guard let self else { return }
            if !isCompose && !isChat {
                // Don't interfere with ConversationEngine — it manages its own interaction state.
                if self.conversationEngine?.isConversationActive != true
                    && !self.viewModel.isGameActive
                {
                    self.panelController?.disableInteraction()
                }
            }
        }

        // When minimize state actually transitions, resize the panel to match
        // the strip (narrower) or the card (wider).
        // .removeDuplicates() prevents spurious firings from redundant
        // `isMinimized = false` assignments in applyChat / apply / clear / etc.
        let minimizeObserver = viewModel.$isMinimized
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isMinimized in
                guard let self else { return }
                let h = self.viewModel.interactiveCardHeight
                if isMinimized {
                    self.panelController?.enableMinimizedInteraction(
                        stripWidth: self.settings.notchVisualWidth,
                        smallMode: self.settings.smallMode,
                        contentHeight: h
                    )
                } else if self.viewModel.isChatActive || self.viewModel.isComposeActive
                    || self.viewModel.isGameActive
                {
                    // Restore full-card-width interaction
                    self.panelController?.enableInteraction(
                        smallMode: self.settings.smallMode,
                        contentHeight: h
                    )
                }
            }

        // When the card height changes (animation, input appears, etc.),
        // resize the panel to match so transparent areas below the card
        // don't capture mouse events.
        let heightObserver = viewModel.$interactiveCardHeight
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] height in
                guard let self, height > 10 else { return }
                if self.viewModel.isMinimized {
                    self.panelController?.enableMinimizedInteraction(
                        stripWidth: self.settings.notchVisualWidth,
                        smallMode: self.settings.smallMode,
                        contentHeight: height
                    )
                } else if self.viewModel.isChatActive || self.viewModel.isComposeActive
                    || self.viewModel.isGameActive
                {
                    self.panelController?.enableInteraction(
                        smallMode: self.settings.smallMode,
                        contentHeight: height
                    )
                }
            }

        interactionObservers = [interactionObserver, minimizeObserver, heightObserver]
    }

    /// Re-assert panel pass-through after the machine wakes from sleep.
    /// Screen layout may also change (e.g. external monitor disconnected).
    private func observeSleepWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Re-position the panel (screen layout may have changed).
            self.panelController?.updateFrame()
            self.panelController?.show()
            // If nothing interactive is currently showing, ensure pass-through.
            if !self.viewModel.isComposeActive
                && !self.viewModel.isChatActive
                && !self.viewModel.isGameActive
                && self.conversationEngine?.isConversationActive != true
            {
                self.panelController?.disableInteraction()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .displayConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !DisplayStateMonitor.isLidClosed() {
                // Lid just opened — reposition panel to built-in display
                self.panelController?.updateFrame()
                self.panelController?.show()
                LogStore.shared.info(
                    "Display", "Lid opened — panel repositioned to built-in display")
            }
        }
    }

    private func openCompose() {
        if viewModel.isComposeActive {
            // Already open — dismiss
            viewModel.cancelCompose()
            panelController?.disableInteraction()
            return
        }
        // Resolve the target character name so the compose card can show it.
        let targetName =
            characterStore.characters.first(where: { $0.name == "Aki" })?.name
            ?? characterStore.characters.first?.name
            ?? ""
        viewModel.openCompose(characterName: targetName)
        panelController?.show()
        panelController?.enableInteraction(
            smallMode: settings.smallMode,
            contentHeight: viewModel.interactiveCardHeight
        )
    }

    /// Resolve a character name from the CharacterStore and return enriched overlay fields.
    /// Returns (name, accentHex, imageBase64) or nil if the character isn't found.
    private func resolveCharacter(name: String, face: String?) -> (
        name: String, accentHex: String, imageBase64: String?
    )? {
        guard
            let character = characterStore.characters.first(where: {
                $0.name.lowercased() == name.lowercased()
            })
        else { return nil }

        let faceName = face?.lowercased() ?? character.faceNames.randomElement()
        let imageBase64 = faceName.flatMap { character.getFaceBase64($0) }

        return (name: character.name, accentHex: character.accentHex, imageBase64: imageBase64)
    }

    /// Route a user message through the built-in agent brain (if any character enabled) or external endpoint.
    func routeUserMessage(_ message: String, images: [Data] = []) {
        if !message.isEmpty {
            HistoryStore.shared.recordUserMessage(message: message)
        }
        guard let brain = agentBrain else {
            // Fall back to external endpoint
            NotchOverlayViewModel.postToTalk(
                message: message, images: images, endpoint: settings.talkEndpointURL)
            return
        }
        // Use the first character (or Aki if available)
        let character =
            characterStore.characters.first(where: { $0.name == "Aki" })
            ?? characterStore.characters.first
        guard let character else { return }
        Task {
            await brain.think(
                character: character,
                triggerContext: "master wants to talk to you directly: \(message)",
                images: images)
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings", action: #selector(openSettingsFromDock), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let testItem = NSMenuItem(
            title: "Test Payload", action: #selector(sendTestPayload), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        let testChatItem = NSMenuItem(
            title: "Test Chat", action: #selector(sendTestChat), keyEquivalent: "")
        testChatItem.target = self
        menu.addItem(testChatItem)

        let testConvoItem = NSMenuItem(
            title: "Test Conversation", action: #selector(sendTestConversation), keyEquivalent: "")
        testConvoItem.target = self
        testConvoItem.isEnabled = characterStore.characters.count >= 2
        menu.addItem(testConvoItem)

        menu.addItem(NSMenuItem.separator())

        let gameMenu = NSMenu()
        let ticTacToeItem = NSMenuItem(
            title: "Tic-Tac-Toe", action: #selector(testTicTacToe), keyEquivalent: "")
        ticTacToeItem.target = self
        gameMenu.addItem(ticTacToeItem)

        let snakeItem = NSMenuItem(
            title: "Snake", action: #selector(testSnake), keyEquivalent: "")
        snakeItem.target = self
        gameMenu.addItem(snakeItem)

        let hangmanItem = NSMenuItem(
            title: "Hangman", action: #selector(testHangman), keyEquivalent: "")
        hangmanItem.target = self
        gameMenu.addItem(hangmanItem)

        let gamesItem = NSMenuItem(title: "Games", action: nil, keyEquivalent: "")
        gamesItem.submenu = gameMenu
        menu.addItem(gamesItem)

        let composeItem = NSMenuItem(
            title: "Compose", action: #selector(composeFromDock), keyEquivalent: "")
        composeItem.target = self
        menu.addItem(composeItem)

        menu.addItem(NSMenuItem.separator())

        let smallItem = NSMenuItem(
            title: "Small Mode", action: #selector(toggleSmallMode), keyEquivalent: "")
        smallItem.target = self
        smallItem.state = settings.smallMode ? .on : .off
        menu.addItem(smallItem)

        return menu
    }

    @objc private func openSettingsFromDock() {
        showSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleSmallMode() {
        settings.smallMode.toggle()
    }

    @objc private func composeFromDock() {
        openCompose()
    }

    @objc private func sendTestPayload() {
        viewModel.showTestCard(appearanceDuration: settings.appearanceDuration, settings: settings)
        panelController?.show()
    }

    @objc private func sendTestChat() {
        viewModel.showTestChat(settings: settings) { [weak self] answer in
            print("[Test Chat] User answered: \(answer)")
            guard let self else { return }
            if answer.lowercased() == "maybe" {
                self.sendFollowUpChat()
            } else {
                self.panelController?.disableInteraction()
            }
        }
        panelController?.show()
        panelController?.enableInteraction(
            smallMode: settings.smallMode,
            contentHeight: viewModel.interactiveCardHeight
        )
    }

    @objc private func sendTestConversation() {
        let characters = characterStore.characters
        guard characters.count >= 2 else {
            print("[Test Conversation] Need at least 2 characters")
            return
        }

        // Pick the first two characters for the test conversation
        let participants = Array(characters.prefix(2))
        let names = participants.map(\.name).joined(separator: " & ")
        print("[Test Conversation] Starting conversation between \(names)")

        guard let engine = conversationEngine else {
            // If agents aren't running, spin up a temporary engine
            guard let panel = panelController else { return }
            let tempEngine = ConversationEngine(
                providerStore: providerStore,
                viewModel: viewModel,
                panelController: panel,
                settings: settings
            )
            tempEngine.startConversation(
                participants: participants,
                context: "You just bumped into each other — have a quick, fun chat!",
                maxTurns: 4,
                pauseBetweenTurns: 1.0
            )
            return
        }

        engine.startConversation(
            participants: participants,
            context: "You just bumped into each other — have a quick, fun chat!",
            maxTurns: 4,
            pauseBetweenTurns: 1.0
        )
    }

    // MARK: - Test Games

    @objc private func testTicTacToe() {
        let character = characterStore.characters.first
        gameViewModel.settings = settings
        gameViewModel.completionHandler = { [weak self] result in
            print("[Test Game] \(result.description)")
            self?.viewModel.endGame()
            self?.panelController?.disableInteraction()
        }
        gameViewModel.startTicTacToe(
            characterName: character?.name ?? "Aki",
            accentHex: character?.accentHex ?? "#7FD6FF",
            faceData: character?.faces.values.first
        )
        viewModel.startGame(gameVM: gameViewModel)
        panelController?.show()
        panelController?.enableInteraction(
            smallMode: settings.smallMode,
            contentHeight: viewModel.interactiveCardHeight
        )
    }

    @objc private func testSnake() {
        let character = characterStore.characters.first
        gameViewModel.settings = settings
        gameViewModel.completionHandler = { [weak self] result in
            print("[Test Game] \(result.description)")
            self?.viewModel.endGame()
            self?.panelController?.disableInteraction()
        }
        gameViewModel.startSnake(
            characterName: character?.name ?? "Aki",
            accentHex: character?.accentHex ?? "#7FD6FF",
            faceData: character?.faces.values.first
        )
        viewModel.startGame(gameVM: gameViewModel)
        panelController?.show()
        panelController?.enableInteraction(
            smallMode: settings.smallMode,
            contentHeight: viewModel.interactiveCardHeight
        )
    }

    @objc private func testHangman() {
        let character = characterStore.characters.first
        gameViewModel.settings = settings
        gameViewModel.completionHandler = { [weak self] result in
            print("[Test Game] \(result.description)")
            self?.viewModel.endGame()
            self?.panelController?.disableInteraction()
        }
        gameViewModel.startHangman(
            word: HangmanEngine.wordBank.randomElement() ?? "SWIFT",
            mode: .userGuesses,
            characterName: character?.name ?? "Aki",
            accentHex: character?.accentHex ?? "#7FD6FF",
            faceData: character?.faces.values.first
        )
        viewModel.startGame(gameVM: gameViewModel)
        panelController?.show()
        panelController?.enableInteraction(
            smallMode: settings.smallMode,
            contentHeight: viewModel.interactiveCardHeight
        )
    }

    private func sendFollowUpChat() {
        let request = ChatAPIRequest(
            title: nil,
            name: settings.testName,
            nameColor: settings.testNameColorHex,
            message: "Why ?",
            imageURL: nil,
            imageBase64: nil,
            accentHex: settings.testNameColorHex,
            proposedAnswers: nil
        )
        viewModel.applyChat(request) { [weak self] answer in
            self?.panelController?.disableInteraction()
            print("[Test Chat follow-up] User answered: \(answer)")
        }
        panelController?.show()
        panelController?.enableInteraction(
            smallMode: settings.smallMode,
            contentHeight: viewModel.interactiveCardHeight
        )
    }

    @objc func showSettingsWindow() {
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = SettingsView(
            settings: settings, characterStore: characterStore,
            providerStore: providerStore,
            licenseManager: licenseManager,
            updater: updaterReady ? updaterController.updater : nil,
            onAgentsChanged: { [weak self] in
                self?.startAgentsIfEnabled()
            },
            onActivateLicense: { [weak self] in
                self?.showActivationWindow()
            })
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 840, height: 700))
        window.minSize = NSSize(width: 700, height: 500)
        window.center()

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        settingsWindowController = controller
    }
}

@main
struct aki_notch_uiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                settings: appDelegate.settings, characterStore: appDelegate.characterStore,
                providerStore: appDelegate.providerStore,
                licenseManager: appDelegate.licenseManager,
                updater: appDelegate.updaterReady ? appDelegate.updaterController.updater : nil,
                onAgentsChanged: {
                    appDelegate.startAgentsIfEnabled()
                },
                onActivateLicense: {
                    appDelegate.showActivationWindow()
                }
            )
            .frame(minWidth: 600, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    appDelegate.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - Sparkle Updater Delegate

extension AppDelegate: SPUUpdaterDelegate {
    /// Hardcoded fallback so Sparkle always finds the feed URL, even if
    /// the generated Info.plist hasn't been loaded yet.
    func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://aki-notch.app/appcast.xml"
    }
}
