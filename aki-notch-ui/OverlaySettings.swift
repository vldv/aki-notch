// OverlaySettings.swift — aki-notch-ui

import Combine
import Foundation
import SwiftUI

// MARK: - Settings

@MainActor
final class OverlaySettings: ObservableObject {

    // -- Timing --
    @Published var appearanceDuration: TimeInterval {
        didSet {
            UserDefaults.standard.set(appearanceDuration, forKey: "overlay.appearanceDuration")
        }
    }

    // -- Colors --
    @Published var bgColorHex: String {
        didSet { UserDefaults.standard.set(bgColorHex, forKey: "overlay.bgColorHex") }
    }
    @Published var borderColorHex: String {
        didSet { UserDefaults.standard.set(borderColorHex, forKey: "overlay.borderColorHex") }
    }
    @Published var textColorHex: String {
        didSet { UserDefaults.standard.set(textColorHex, forKey: "overlay.textColorHex") }
    }

    // -- Position --
    @Published var notchOffset: CGFloat {
        didSet { UserDefaults.standard.set(Double(notchOffset), forKey: "overlay.notchOffset") }
    }
    @Published var horizontalOffset: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(horizontalOffset), forKey: "overlay.horizontalOffset")
        }
    }

    // -- Shape / Notch alignment --
    /// Visual width of the initial narrow drop, tuned to match the physical notch.
    /// Divide by the current scale factor before use: `notchVisualWidth / scale`.
    @Published var notchVisualWidth: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(notchVisualWidth), forKey: "overlay.notchVisualWidth")
        }
    }
    @Published var cornerRadius: CGFloat {
        didSet { UserDefaults.standard.set(Double(cornerRadius), forKey: "overlay.cornerRadius") }
    }
    @Published var borderWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(borderWidth), forKey: "overlay.borderWidth") }
    }

    // -- Text animation --
    @Published var textSpeed: Double {
        didSet { UserDefaults.standard.set(textSpeed, forKey: "overlay.textSpeed") }
    }

    // -- Display mode --
    @Published var smallMode: Bool {
        didSet { UserDefaults.standard.set(smallMode, forKey: "overlay.smallMode") }
    }

    // -- Call suppression --
    /// When enabled, triggers are suppressed while the microphone is in use
    /// (i.e. the user is likely on an audio/video call).
    @Published var suppressOnMicActive: Bool {
        didSet {
            UserDefaults.standard.set(suppressOnMicActive, forKey: "overlay.suppressOnMicActive")
        }
    }
    /// When enabled, triggers are suppressed while the camera is in use
    /// (i.e. the user is likely on a video call).
    @Published var suppressOnCameraActive: Bool {
        didSet {
            UserDefaults.standard.set(
                suppressOnCameraActive, forKey: "overlay.suppressOnCameraActive")
        }
    }

    // -- Startup --
    @Published var startupEnabled: Bool {
        didSet { UserDefaults.standard.set(startupEnabled, forKey: "overlay.startupEnabled") }
    }
    @Published var startupName: String {
        didSet { UserDefaults.standard.set(startupName, forKey: "overlay.startupName") }
    }
    @Published var startupNameColorHex: String {
        didSet {
            UserDefaults.standard.set(startupNameColorHex, forKey: "overlay.startupNameColorHex")
        }
    }
    @Published var startupMessage: String {
        didSet { UserDefaults.standard.set(startupMessage, forKey: "overlay.startupMessage") }
    }

    // -- App Presence --
    @Published var showDockIcon: Bool {
        didSet { UserDefaults.standard.set(showDockIcon, forKey: "overlay.showDockIcon") }
    }
    @Published var showStatusBarIcon: Bool {
        didSet { UserDefaults.standard.set(showStatusBarIcon, forKey: "overlay.showStatusBarIcon") }
    }

    // -- Onboarding --
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(
                hasCompletedOnboarding, forKey: "overlay.hasCompletedOnboarding")
        }
    }

    // -- Compose --
    @Published var talkEndpointURL: String {
        didSet { UserDefaults.standard.set(talkEndpointURL, forKey: "overlay.talkEndpointURL") }
    }

    // -- API Server --
    @Published var apiPort: Int {
        didSet { UserDefaults.standard.set(apiPort, forKey: "overlay.apiPort") }
    }

    // -- Dismiss behavior --
    /// When true, dismissing a chat kills the entire interaction immediately
    /// instead of letting the agent react to the dismissal.
    @Published var hardDismiss: Bool {
        didSet { UserDefaults.standard.set(hardDismiss, forKey: "overlay.hardDismiss") }
    }

    // -- CLI Execution --
    /// When enabled, characters can use the `run_command` tool to execute
    /// shell commands on behalf of the user. Each command requires explicit
    /// user confirmation before execution.
    @Published var allowCLIExecution: Bool {
        didSet { UserDefaults.standard.set(allowCLIExecution, forKey: "overlay.allowCLIExecution") }
    }

    // -- CLI Trusted Prefixes --
    /// Command prefixes that skip the confirmation prompt when CLI execution is enabled.
    /// For example, ["ls", "cat", "pwd"] means commands starting with those words run without asking.
    @Published var cliTrustedPrefixes: [String] {
        didSet {
            UserDefaults.standard.set(cliTrustedPrefixes, forKey: "overlay.cliTrustedPrefixes")
        }
    }

    // -- Dataset logging --
    /// When enabled, agent interactions are logged to ~/.akiapp/datasets/ as JSONL
    /// for future fine-tuning. Images are stripped, only text/tool interactions are recorded.
    @Published var datasetLogging: Bool {
        didSet { UserDefaults.standard.set(datasetLogging, forKey: "overlay.datasetLogging") }
    }

    // -- Session memory --
    /// Maximum number of session messages kept per character before compaction.
    @Published var sessionMaxMessages: Int {
        didSet {
            UserDefaults.standard.set(sessionMaxMessages, forKey: "overlay.sessionMaxMessages")
        }
    }

    /// Maximum age (in days) for session messages. Messages older than this are pruned.
    @Published var sessionMaxAgeDays: Int {
        didSet { UserDefaults.standard.set(sessionMaxAgeDays, forKey: "overlay.sessionMaxAgeDays") }
    }

    // -- Games --
    @Published var ticTacToeDifficulty: TicTacToeDifficulty {
        didSet {
            UserDefaults.standard.set(
                ticTacToeDifficulty.rawValue, forKey: "overlay.ticTacToeDifficulty")
        }
    }

    // -- Test payload (internal, not shown in settings UI) --
    @Published var testName: String {
        didSet { UserDefaults.standard.set(testName, forKey: "overlay.testName") }
    }
    @Published var testNameColorHex: String {
        didSet { UserDefaults.standard.set(testNameColorHex, forKey: "overlay.testNameColorHex") }
    }
    @Published var testMessage: String {
        didSet { UserDefaults.standard.set(testMessage, forKey: "overlay.testMessage") }
    }

    // Defaults
    static let defaultAppearanceDuration: TimeInterval = 6
    static let defaultBgColorHex = "#000000"
    static let defaultBorderColorHex = "#3A3A3A"
    static let defaultTextColorHex = "#E8E8E8"
    static let defaultNotchOffset: CGFloat = 38
    static let defaultHorizontalOffset: CGFloat = 0
    static let defaultNotchVisualWidth: CGFloat = 185
    static let defaultCornerRadius: CGFloat = 20
    static let defaultBorderWidth: CGFloat = 1.5
    static let defaultTextSpeed: Double = 28
    static let defaultSmallMode: Bool = false
    static let defaultSuppressOnMicActive: Bool = true
    static let defaultSuppressOnCameraActive: Bool = true
    static let defaultStartupEnabled: Bool = true
    static let defaultStartupName = "Aki"
    static let defaultStartupNameColorHex = "#7FD6FF"
    static let defaultStartupMessage = "Systems online.\nAwaiting orders."
    static let defaultShowDockIcon: Bool = true
    static let defaultShowStatusBarIcon: Bool = true
    static let defaultHasCompletedOnboarding: Bool = false
    static let defaultTalkEndpointURL = "http://127.0.0.1:8787/talk"
    static let defaultAPIPort: Int = 47037
    static let defaultHardDismiss: Bool = false
    static let defaultAllowCLIExecution: Bool = false
    static let defaultCLITrustedPrefixes: [String] = []
    static let defaultDatasetLogging: Bool = false
    static let defaultSessionMaxMessages: Int = 50
    static let defaultSessionMaxAgeDays: Int = 5
    static let defaultTicTacToeDifficulty: TicTacToeDifficulty = .hard
    static let defaultTestName = "Aki"
    static let defaultTestNameColorHex = "#7FD6FF"
    static let defaultTestMessage = "Hi victor!\nHow are you?"

    init() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            "overlay.appearanceDuration": Self.defaultAppearanceDuration,
            "overlay.bgColorHex": Self.defaultBgColorHex,
            "overlay.borderColorHex": Self.defaultBorderColorHex,
            "overlay.textColorHex": Self.defaultTextColorHex,
            "overlay.notchOffset": Double(Self.defaultNotchOffset),
            "overlay.horizontalOffset": Double(Self.defaultHorizontalOffset),
            "overlay.notchVisualWidth": Double(Self.defaultNotchVisualWidth),
            "overlay.cornerRadius": Double(Self.defaultCornerRadius),
            "overlay.borderWidth": Double(Self.defaultBorderWidth),
            "overlay.textSpeed": Self.defaultTextSpeed,
            "overlay.smallMode": Self.defaultSmallMode,
            "overlay.suppressOnMicActive": Self.defaultSuppressOnMicActive,
            "overlay.suppressOnCameraActive": Self.defaultSuppressOnCameraActive,
            "overlay.startupEnabled": Self.defaultStartupEnabled,
            "overlay.startupName": Self.defaultStartupName,
            "overlay.startupNameColorHex": Self.defaultStartupNameColorHex,
            "overlay.startupMessage": Self.defaultStartupMessage,
            "overlay.showDockIcon": Self.defaultShowDockIcon,
            "overlay.showStatusBarIcon": Self.defaultShowStatusBarIcon,
            "overlay.hasCompletedOnboarding": Self.defaultHasCompletedOnboarding,
            "overlay.talkEndpointURL": Self.defaultTalkEndpointURL,
            "overlay.apiPort": Self.defaultAPIPort,
            "overlay.hardDismiss": Self.defaultHardDismiss,
            "overlay.allowCLIExecution": Self.defaultAllowCLIExecution,
            "overlay.cliTrustedPrefixes": Self.defaultCLITrustedPrefixes,
            "overlay.datasetLogging": Self.defaultDatasetLogging,
            "overlay.sessionMaxMessages": Self.defaultSessionMaxMessages,
            "overlay.sessionMaxAgeDays": Self.defaultSessionMaxAgeDays,
            "overlay.ticTacToeDifficulty": TicTacToeDifficulty.hard.rawValue,
            "overlay.testName": Self.defaultTestName,
            "overlay.testNameColorHex": Self.defaultTestNameColorHex,
            "overlay.testMessage": Self.defaultTestMessage,
        ])

        self.appearanceDuration = ud.double(forKey: "overlay.appearanceDuration")
        self.bgColorHex = ud.string(forKey: "overlay.bgColorHex") ?? Self.defaultBgColorHex
        self.borderColorHex =
            ud.string(forKey: "overlay.borderColorHex") ?? Self.defaultBorderColorHex
        self.textColorHex = ud.string(forKey: "overlay.textColorHex") ?? Self.defaultTextColorHex
        self.notchOffset = CGFloat(ud.double(forKey: "overlay.notchOffset"))
        self.horizontalOffset = CGFloat(ud.double(forKey: "overlay.horizontalOffset"))
        self.notchVisualWidth = CGFloat(ud.double(forKey: "overlay.notchVisualWidth"))
        self.cornerRadius = CGFloat(ud.double(forKey: "overlay.cornerRadius"))
        self.borderWidth = CGFloat(ud.double(forKey: "overlay.borderWidth"))
        self.textSpeed = ud.double(forKey: "overlay.textSpeed")
        self.smallMode = ud.bool(forKey: "overlay.smallMode")
        self.suppressOnMicActive = ud.bool(forKey: "overlay.suppressOnMicActive")
        self.suppressOnCameraActive = ud.bool(forKey: "overlay.suppressOnCameraActive")
        self.startupEnabled = ud.bool(forKey: "overlay.startupEnabled")
        self.startupName =
            ud.string(forKey: "overlay.startupName") ?? Self.defaultStartupName
        self.startupNameColorHex =
            ud.string(forKey: "overlay.startupNameColorHex") ?? Self.defaultStartupNameColorHex
        self.startupMessage =
            ud.string(forKey: "overlay.startupMessage") ?? Self.defaultStartupMessage
        // Use registered defaults, but guard against false-negative on first launch
        if ud.object(forKey: "overlay.showDockIcon") == nil {
            self.showDockIcon = Self.defaultShowDockIcon
        } else {
            self.showDockIcon = ud.bool(forKey: "overlay.showDockIcon")
        }
        if ud.object(forKey: "overlay.showStatusBarIcon") == nil {
            self.showStatusBarIcon = Self.defaultShowStatusBarIcon
        } else {
            self.showStatusBarIcon = ud.bool(forKey: "overlay.showStatusBarIcon")
        }
        self.hasCompletedOnboarding = ud.bool(forKey: "overlay.hasCompletedOnboarding")
        self.talkEndpointURL =
            ud.string(forKey: "overlay.talkEndpointURL") ?? Self.defaultTalkEndpointURL
        let savedPort = ud.integer(forKey: "overlay.apiPort")
        self.apiPort = savedPort != 0 ? savedPort : Self.defaultAPIPort
        if ud.object(forKey: "overlay.hardDismiss") == nil {
            self.hardDismiss = Self.defaultHardDismiss
        } else {
            self.hardDismiss = ud.bool(forKey: "overlay.hardDismiss")
        }
        if ud.object(forKey: "overlay.allowCLIExecution") == nil {
            self.allowCLIExecution = Self.defaultAllowCLIExecution
        } else {
            self.allowCLIExecution = ud.bool(forKey: "overlay.allowCLIExecution")
        }
        self.cliTrustedPrefixes =
            ud.stringArray(forKey: "overlay.cliTrustedPrefixes") ?? Self.defaultCLITrustedPrefixes
        if ud.object(forKey: "overlay.datasetLogging") == nil {
            self.datasetLogging = Self.defaultDatasetLogging
        } else {
            self.datasetLogging = ud.bool(forKey: "overlay.datasetLogging")
        }
        let savedMaxMessages = ud.integer(forKey: "overlay.sessionMaxMessages")
        self.sessionMaxMessages =
            savedMaxMessages > 0 ? savedMaxMessages : Self.defaultSessionMaxMessages
        let savedMaxAge = ud.integer(forKey: "overlay.sessionMaxAgeDays")
        self.sessionMaxAgeDays = savedMaxAge > 0 ? savedMaxAge : Self.defaultSessionMaxAgeDays
        let savedDifficulty =
            ud.string(forKey: "overlay.ticTacToeDifficulty") ?? TicTacToeDifficulty.hard.rawValue
        self.ticTacToeDifficulty = TicTacToeDifficulty(rawValue: savedDifficulty) ?? .hard
        self.testName = ud.string(forKey: "overlay.testName") ?? Self.defaultTestName
        self.testNameColorHex =
            ud.string(forKey: "overlay.testNameColorHex") ?? Self.defaultTestNameColorHex
        self.testMessage = ud.string(forKey: "overlay.testMessage") ?? Self.defaultTestMessage
    }

    func resetToDefaults() {
        appearanceDuration = Self.defaultAppearanceDuration
        bgColorHex = Self.defaultBgColorHex
        borderColorHex = Self.defaultBorderColorHex
        textColorHex = Self.defaultTextColorHex
        notchOffset = Self.defaultNotchOffset
        horizontalOffset = Self.defaultHorizontalOffset
        notchVisualWidth = Self.defaultNotchVisualWidth
        cornerRadius = Self.defaultCornerRadius
        borderWidth = Self.defaultBorderWidth
        textSpeed = Self.defaultTextSpeed
        smallMode = Self.defaultSmallMode
        suppressOnMicActive = Self.defaultSuppressOnMicActive
        suppressOnCameraActive = Self.defaultSuppressOnCameraActive
        startupEnabled = Self.defaultStartupEnabled
        startupName = Self.defaultStartupName
        startupNameColorHex = Self.defaultStartupNameColorHex
        startupMessage = Self.defaultStartupMessage
        showDockIcon = Self.defaultShowDockIcon
        showStatusBarIcon = Self.defaultShowStatusBarIcon
        talkEndpointURL = Self.defaultTalkEndpointURL
        apiPort = Self.defaultAPIPort
        testName = Self.defaultTestName
        testNameColorHex = Self.defaultTestNameColorHex
        testMessage = Self.defaultTestMessage
        hardDismiss = Self.defaultHardDismiss
        allowCLIExecution = Self.defaultAllowCLIExecution
        cliTrustedPrefixes = Self.defaultCLITrustedPrefixes
        datasetLogging = Self.defaultDatasetLogging
        sessionMaxMessages = Self.defaultSessionMaxMessages
        sessionMaxAgeDays = Self.defaultSessionMaxAgeDays
        ticTacToeDifficulty = Self.defaultTicTacToeDifficulty
    }
}
