//
//  TriggerEngine.swift
//  aki-notch-ui
//
//  Manages random and scheduled triggers that fire the agent brain.
//  Ported from the Python backend's trigger system.
//

import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "TriggerEngine")

// MARK: - Trigger Configuration Models

/// Configures a single trigger instance (random or scheduled).
struct TriggerConfig: Codable, Identifiable {
    let id: UUID
    var type: TriggerType

    // Random trigger params
    var minIntervalMinutes: Double
    var maxIntervalMinutes: Double

    // Scheduled trigger params
    var schedule: [ScheduleEntry]

    init(type: TriggerType) {
        self.id = UUID()
        self.type = type

        switch type {
        case .random:
            self.minIntervalMinutes = 45
            self.maxIntervalMinutes = 180
            self.schedule = []
        case .scheduled:
            self.minIntervalMinutes = 45
            self.maxIntervalMinutes = 180
            self.schedule = []
        }
    }

    enum TriggerType: String, Codable {
        case random
        case scheduled
    }
}

/// A single time-of-day entry within a scheduled trigger.
struct ScheduleEntry: Codable, Identifiable {
    let id: UUID
    var time: String  // "HH:mm" format, e.g. "09:30"
    var context: String  // e.g. "morning — time to greet"

    init(time: String = "09:00", context: String = "") {
        self.id = UUID()
        self.time = time
        self.context = context
    }
}

extension ScheduleEntry {
    /// Seconds from now until the next occurrence of this time (in local timezone).
    func secondsUntilNext() -> Double {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 3600 }

        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = 0

        guard var target = calendar.date(from: components) else { return 3600 }

        // If the target time already passed today, advance to tomorrow.
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }

        return target.timeIntervalSince(now)
    }
}

// MARK: - Per-Character Trigger Configuration

/// Stored per character as `triggers.json` inside the character's directory.
struct CharacterTriggerConfig: Codable {
    var enabled: Bool
    var triggers: [TriggerConfig]
    var startupGreeting: Bool
    var startupGreetingDelay: Double  // seconds to wait before startup greeting
    var conversations: [ConversationConfig]  // multi-character conversation triggers

    /// Memberwise initializer.
    init(
        enabled: Bool = true,
        triggers: [TriggerConfig] = [],
        startupGreeting: Bool = false,
        startupGreetingDelay: Double = 0,
        conversations: [ConversationConfig] = []
    ) {
        self.enabled = enabled
        self.triggers = triggers
        self.startupGreeting = startupGreeting
        self.startupGreetingDelay = startupGreetingDelay
        self.conversations = conversations
    }

    static let `default` = CharacterTriggerConfig()

    /// Backward-compatible decoding — old files without newer fields use sensible defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.triggers = try container.decodeIfPresent([TriggerConfig].self, forKey: .triggers) ?? []
        self.startupGreeting =
            try container.decodeIfPresent(Bool.self, forKey: .startupGreeting) ?? false
        self.startupGreetingDelay =
            try container.decodeIfPresent(Double.self, forKey: .startupGreetingDelay) ?? 0
        self.conversations =
            try container.decodeIfPresent([ConversationConfig].self, forKey: .conversations) ?? []
    }

    /// Load from a character's directory (`triggers.json`).
    static func load(from directory: URL) -> CharacterTriggerConfig {
        let url = directory.appendingPathComponent("triggers.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("No triggers.json found in \(directory.lastPathComponent), using defaults")
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(CharacterTriggerConfig.self, from: data)
            logger.info("Loaded trigger config for \(directory.lastPathComponent)")
            return config
        } catch {
            logger.warning(
                "Failed to parse triggers.json in \(directory.lastPathComponent): \(error.localizedDescription)"
            )
            return .default
        }
    }

    /// Save to a character's directory.
    func save(to directory: URL) {
        let url = directory.appendingPathComponent("triggers.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else {
            logger.error("Failed to encode trigger config for \(directory.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error(
                "Failed to write triggers.json to \(directory.lastPathComponent): \(error.localizedDescription)"
            )
        }
        logger.info("Saved trigger config to \(directory.lastPathComponent)/triggers.json")
    }
}

// MARK: - Trigger Engine

/// Manages active trigger loops (random & scheduled) for all loaded characters.
/// Fires a callback each time a trigger activates so the agent brain can respond.
@MainActor
final class TriggerEngine: ObservableObject {
    typealias TriggerCallback = (Character, String) async -> Void
    typealias ConversationCallback = ([Character], String, Int, Double) -> Void

    @Published var isRunning = false

    private var tasks: [Task<Void, Never>] = []
    private var callback: TriggerCallback?
    private var conversationCallback: ConversationCallback?
    private weak var settings: OverlaySettings?
    private weak var characterStore: CharacterStore?

    // MARK: - Public API

    /// Start all triggers for the given characters with their configs.
    func start(
        characters: [(character: Character, config: CharacterTriggerConfig)],
        settings: OverlaySettings,
        characterStore: CharacterStore,
        callback: @escaping TriggerCallback,
        conversationCallback: @escaping ConversationCallback
    ) {
        stop()  // stop any existing triggers
        self.callback = callback
        self.conversationCallback = conversationCallback
        self.settings = settings
        self.characterStore = characterStore
        isRunning = true

        // Track conversation configs already scheduled (by ID) to avoid duplicates
        // when the same conversation is referenced by multiple participants.
        var scheduledConversationIDs: Set<UUID> = []

        for (character, config) in characters {
            for trigger in config.triggers {
                switch trigger.type {
                case .random:
                    tasks.append(startRandomTrigger(character: character, config: trigger))
                case .scheduled:
                    tasks.append(startScheduledTrigger(character: character, config: trigger))
                }
            }

            // Schedule conversation triggers (deduplicated)
            for convo in config.conversations {
                guard !scheduledConversationIDs.contains(convo.id) else { continue }
                scheduledConversationIDs.insert(convo.id)
                tasks.append(startConversationTrigger(config: convo))
            }
        }

        logger.info("Started \(self.tasks.count) trigger(s)")
        LogStore.shared.info("Trigger", "Started \(self.tasks.count) trigger(s)")
    }

    /// Fire startup greetings for characters that have them enabled.
    func fireStartupGreetings(
        characters: [(character: Character, config: CharacterTriggerConfig)]
    ) {
        for (character, config) in characters where config.startupGreeting {
            let delay = config.startupGreetingDelay
            tasks.append(
                Task {
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    await self.callback?(character, "app just started — say hello to your user!")
                })
        }
    }

    /// Cancel all running trigger tasks.
    func stop() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        isRunning = false
        conversationCallback = nil
        characterStore = nil
        logger.info("All triggers stopped")
        LogStore.shared.info("Trigger", "All triggers stopped")
    }

    // MARK: - Private Trigger Loops

    /// Spawns a long-running task that fires at random intervals.
    private func startRandomTrigger(character: Character, config: TriggerConfig) -> Task<
        Void, Never
    > {
        let minSeconds = config.minIntervalMinutes * 60
        let maxSeconds = config.maxIntervalMinutes * 60

        return Task {
            // Initial jittered delay so triggers don't all fire at once.
            try? await Task.sleep(for: .seconds(Double.random(in: 10...30)))

            while !Task.isCancelled {
                let delay = Double.random(in: minSeconds...maxSeconds)
                logger.info(
                    "[RandomTrigger] Next fire for \(character.name) in \(delay / 60, format: .fixed(precision: 1)) min"
                )
                LogStore.shared.debug(
                    "Trigger",
                    "⏱ Random trigger for \(character.name) in \(String(format: "%.1f", delay / 60)) min"
                )
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }

                if self.shouldSuppressForCall() {
                    logger.info(
                        "[RandomTrigger] Suppressed for \(character.name) — microphone in use (likely on a call)"
                    )
                    LogStore.shared.warning(
                        "Trigger",
                        "🔇 Suppressed random trigger for \(character.name) — call detected")
                    continue
                }

                if self.shouldSuppressForLidClosed() {
                    logger.info(
                        "[RandomTrigger] Suppressed for \(character.name) — lid closed"
                    )
                    LogStore.shared.info(
                        "Trigger",
                        "💤 Suppressed random trigger for \(character.name) — lid closed")
                    continue
                }

                LogStore.shared.info(
                    "Trigger", "🎲 Random trigger fired for \(character.name)")
                await self.callback?(
                    character, "random — you felt like saying something spontaneously")
            }
        }
    }

    /// Spawns a task that manages one sub-task per schedule entry.
    private func startScheduledTrigger(character: Character, config: TriggerConfig) -> Task<
        Void, Never
    > {
        return Task {
            await withTaskGroup(of: Void.self) { group in
                for entry in config.schedule {
                    group.addTask {
                        await self.runScheduleEntry(character: character, entry: entry)
                    }
                }
            }
        }
    }

    /// Loops forever, sleeping until the next occurrence of `entry.time` and firing.
    private func runScheduleEntry(character: Character, entry: ScheduleEntry) async {
        while !Task.isCancelled {
            let secondsUntilNext = entry.secondsUntilNext()
            logger.info(
                "[ScheduledTrigger] \(character.name) — next '\(entry.context)' in \(secondsUntilNext / 60, format: .fixed(precision: 1)) min"
            )
            LogStore.shared.debug(
                "Trigger",
                "⏱ Scheduled trigger for \(character.name) (\(entry.context)) in \(String(format: "%.1f", secondsUntilNext / 60)) min"
            )
            try? await Task.sleep(for: .seconds(secondsUntilNext))
            guard !Task.isCancelled else { break }

            if self.shouldSuppressForCall() {
                logger.info(
                    "[ScheduledTrigger] Suppressed for \(character.name) — microphone in use (likely on a call)"
                )
                LogStore.shared.warning(
                    "Trigger",
                    "🔇 Suppressed scheduled trigger for \(character.name) (\(entry.context)) — call detected"
                )
                // Don't retry — the schedule entry will fire again tomorrow.
            } else if self.shouldSuppressForLidClosed() {
                logger.info(
                    "[ScheduledTrigger] Suppressed for \(character.name) — lid closed"
                )
                LogStore.shared.info(
                    "Trigger",
                    "💤 Suppressed scheduled trigger for \(character.name) (\(entry.context)) — lid closed")
                // Don't retry — the schedule entry will fire again tomorrow.
            } else {
                LogStore.shared.info(
                    "Trigger",
                    "📅 Scheduled trigger fired for \(character.name): \(entry.context)")
                await self.callback?(character, entry.context)
            }

            // Sleep 61 seconds past the target minute to avoid double-firing.
            try? await Task.sleep(for: .seconds(61))
        }
    }

    // MARK: - Conversation Trigger

    /// Spawns a task that fires a multi-character conversation at random intervals.
    /// The conversation config specifies participants, context, max turns, and timing.
    private func startConversationTrigger(config: ConversationConfig) -> Task<Void, Never> {
        let minSeconds = config.minIntervalMinutes * 60
        let maxSeconds = config.maxIntervalMinutes * 60

        return Task {
            // Initial jittered delay.
            try? await Task.sleep(for: .seconds(Double.random(in: 15...45)))

            while !Task.isCancelled {
                let delay = Double.random(in: minSeconds...maxSeconds)
                let names = config.participantNames.joined(separator: " & ")
                logger.info(
                    "[ConversationTrigger] Next '\(names)' in \(delay / 60, format: .fixed(precision: 1)) min"
                )
                LogStore.shared.debug(
                    "Trigger",
                    "⏱ Conversation trigger (\(names)) in \(String(format: "%.1f", delay / 60)) min"
                )
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }

                if self.shouldSuppressForCall() {
                    logger.info(
                        "[ConversationTrigger] Suppressed — microphone/camera in use")
                    LogStore.shared.warning(
                        "Trigger",
                        "🔇 Suppressed conversation trigger (\(names)) — call detected")
                    continue
                }

                if self.shouldSuppressForLidClosed() {
                    logger.info(
                        "[ConversationTrigger] Suppressed — lid closed")
                    LogStore.shared.info(
                        "Trigger",
                        "💤 Suppressed conversation trigger (\(names)) — lid closed")
                    continue
                }

                // Resolve participant Character objects from the store
                guard let store = self.characterStore else { continue }
                let participants = config.participantNames.compactMap { name in
                    store.characters.first { $0.name == name }
                }
                guard participants.count >= 2 else {
                    logger.warning(
                        "[ConversationTrigger] Not enough participants found for '\(names)' — need 2+, got \(participants.count)"
                    )
                    continue
                }

                LogStore.shared.info(
                    "Trigger",
                    "💬 Conversation trigger fired: \(names)")
                self.conversationCallback?(
                    participants,
                    config.contextTemplate,
                    config.maxTurns,
                    config.pauseBetweenTurns
                )
            }
        }
    }

    // MARK: - Call Suppression

    /// Returns `true` if the trigger should be suppressed because the user
    /// appears to be on a call (microphone in use) and suppression is enabled.
    private func shouldSuppressForCall() -> Bool {
        guard let settings else { return false }

        if settings.suppressOnMicActive, CallDetector.isMicrophoneInUse() {
            return true
        }
        if settings.suppressOnCameraActive, CallDetector.isCameraInUse() {
            return true
        }

        return false
    }


    // MARK: - Lid-Closed Suppression

    /// Returns `true` if the trigger should be suppressed because the
    /// MacBook lid is closed (clamshell mode). Always active.
    private func shouldSuppressForLidClosed() -> Bool {
        DisplayStateMonitor.isLidClosed()
    }
}

