// SettingsView.swift — aki-notch-ui

import Sparkle
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: OverlaySettings
    @ObservedObject var characterStore: CharacterStore
    @ObservedObject var providerStore: ProviderStore
    @ObservedObject var licenseManager: LicenseManager
    var updater: SPUUpdater?
    var onAgentsChanged: () -> Void
    var onActivateLicense: (() -> Void)?
    @State private var selectedTab = 0
    @State private var cliInstallStatus: CLIInstallStatus = .unknown

    private enum CLIInstallStatus: Equatable {
        case unknown
        case installed
        case notInstalled
        case installing
        case needsTerminal(String)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                TabButton(title: "General", isSelected: selectedTab == 0) { selectedTab = 0 }
                TabButton(title: "Overlay", isSelected: selectedTab == 1) { selectedTab = 1 }
                TabButton(title: "Agent", isSelected: selectedTab == 2) { selectedTab = 2 }
                TabButton(title: "Characters", isSelected: selectedTab == 3) { selectedTab = 3 }
                TabButton(title: "Providers", isSelected: selectedTab == 4) { selectedTab = 4 }
                TabButton(title: "Logs", isSelected: selectedTab == 5) { selectedTab = 5 }
                TabButton(title: "History", isSelected: selectedTab == 6) { selectedTab = 6 }
                TabButton(title: "Usage", isSelected: selectedTab == 7) { selectedTab = 7 }
                TabButton(title: "API", isSelected: selectedTab == 8) { selectedTab = 8 }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider().padding(.top, 8)

            switch selectedTab {
            case 0:
                generalSettings
            case 1:
                overlaySettings
            case 2:
                agentSettings
            case 3:
                AgentSettingsView(
                    store: characterStore, providerStore: providerStore,
                    settings: settings, onAgentsChanged: onAgentsChanged)
            case 4:
                ProvidersSettingsView(
                    providerStore: providerStore,
                    onAgentsChanged: onAgentsChanged)
            case 5:
                LiveLogsView()
            case 6:
                HistoryView(characterStore: characterStore)
            case 7:
                UsageView()
            case 8:
                APIDocsView()
            default:
                generalSettings
            }
        }
    }

    // MARK: - General Tab

    private var generalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Updates ─────────────────────────────
                SettingsSection(title: "UPDATES") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let updater {
                            Toggle(
                                isOn: Binding(
                                    get: { updater.automaticallyChecksForUpdates },
                                    set: { updater.automaticallyChecksForUpdates = $0 }
                                )
                            ) {
                                HStack {
                                    Text("Check for updates automatically")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                }
                            }
                            .toggleStyle(.switch)

                            HStack {
                                Text("Check interval")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Picker(
                                    "",
                                    selection: Binding(
                                        get: {
                                            Int(updater.updateCheckInterval)
                                        },
                                        set: {
                                            updater.updateCheckInterval = TimeInterval($0)
                                        }
                                    )
                                ) {
                                    Text("Every hour").tag(3600)
                                    Text("Every 6 hours").tag(21600)
                                    Text("Daily").tag(86400)
                                    Text("Weekly").tag(604800)
                                }
                                .frame(width: 150)
                            }

                            Button("Check for Updates Now") {
                                updater.checkForUpdates()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("Updates unavailable — Sparkle not configured")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // ── App Presence ────────────────────────
                SettingsSection(title: "APP PRESENCE") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            isOn: Binding(
                                get: { settings.showDockIcon },
                                set: { newValue in
                                    if !newValue && !settings.showStatusBarIcon {
                                        settings.showStatusBarIcon = true
                                    }
                                    settings.showDockIcon = newValue
                                }
                            )
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "dock.rectangle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Show in Dock")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Toggle(
                            isOn: Binding(
                                get: { settings.showStatusBarIcon },
                                set: { newValue in
                                    if !newValue && !settings.showDockIcon {
                                        settings.showDockIcon = true
                                    }
                                    settings.showStatusBarIcon = newValue
                                }
                            )
                        ) {
                            HStack(spacing: 6) {
                                Image(systemName: "menubar.rectangle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Show in Menu Bar")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Text(
                            "At least one must stay enabled. Hiding the dock icon also removes the app from ⌘Tab."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                }

                // ── CLI ─────────────────────────────────
                SettingsSection(title: "CLI") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "Install the **aki** command-line tool to use the HTTP API from your terminal."
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            switch cliInstallStatus {
                            case .unknown:
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            case .installed:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 13))
                                Text("CLI installed at /usr/local/bin/aki")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            case .notInstalled:
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.orange)
                                    .font(.system(size: 13))
                                Text("CLI not installed")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            case .installing:
                                ProgressView()
                                    .controlSize(.small)
                                Text("Installing…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            case .needsTerminal:
                                Image(systemName: "terminal")
                                    .foregroundStyle(.blue)
                                    .font(.system(size: 13))
                                Text("Run the command below in Terminal")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            case .error(let message):
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: 13))
                                Text(message)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                            }

                        }

                        if case .needsTerminal(let command) = cliInstallStatus {
                            HStack(spacing: 6) {
                                Text(command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 0.5)
                            }

                            Text("Paste this into Terminal.app, then enter your password.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        Button {
                            installCLI()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 11))
                                Text(
                                    cliInstallStatus == .installed ? "Reinstall CLI" : "Install CLI"
                                )
                                .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(cliInstallStatus == .installing)

                        if case .needsTerminal = cliInstallStatus {
                            // Command block is shown above — skip the example hint.
                        } else {
                            Text("aki notify \"Hello from terminal!\"")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(.quaternary.opacity(0.5))
                                }
                        }
                    }
                    .onAppear {
                        checkCLIInstallStatus()
                    }
                }

                // ── License ─────────────────────────────
                SettingsSection(title: "LICENSE") {
                    VStack(alignment: .leading, spacing: 10) {
                        licenseStatusView

                        if case .active = licenseManager.status {
                            // Already licensed
                        } else {
                            Text(
                                "Enter a license key in the activation window to unlock the full version."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        }

                        Button {
                            onActivateLicense?()
                        } label: {
                            HStack(spacing: 6) {
                                Image(
                                    systemName: licenseManager.isLicensed ? "checkmark.seal" : "key"
                                )
                                .font(.system(size: 11))
                                Text(
                                    licenseManager.isLicensed
                                        ? "Manage License" : "Activate License"
                                )
                                .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // ── Footer ──────────────────────────────
                VStack(spacing: 12) {
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                        as? String,
                        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                    {
                        Text("Aki Notch UI v\(version) (\(build))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
    }

    private var licenseStatusView: some View {
        HStack(spacing: 8) {
            switch licenseManager.status {
            case .trial(let days):
                Image(systemName: "clock")
                    .foregroundStyle(.cyan)
                Text("\(days) day\(days == 1 ? "" : "s") left in trial")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            case .active:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Licensed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            case .expired:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Trial expired")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            case .invalid:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Invalid license")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
    }

    private var agentSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Context ─────────────────────────────
                SettingsSection(title: "CONTEXT") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("User Context File")
                            .font(.system(size: 13, weight: .medium))

                        Text(
                            "Shared context injected into every character's system prompt. Edit ~/.akiapp/context.md to add personal info like your name, location, interests."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        HStack(spacing: 8) {
                            let contextExists = FileManager.default.fileExists(
                                atPath: FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".akiapp/context.md").path
                            )

                            Circle()
                                .fill(contextExists ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(
                                contextExists
                                    ? "context.md found"
                                    : "context.md not found — create it to personalize"
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                let url = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".akiapp")
                                NSWorkspace.shared.open(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "house")
                                    Text("Open ~/.akiapp/")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                // ── Behavior ────────────────────────────
                SettingsSection(title: "BEHAVIOR") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $settings.hardDismiss) {
                            HStack {
                                Text("Hard Dismiss")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Text(
                            "When enabled, pressing DISMISS on a chat kills the interaction immediately. The character won't react or come back with a witty reply."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        Text(
                            "When disabled (default), the character is told you dismissed — and may follow up."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        Divider()

                        Toggle(isOn: $settings.allowCLIExecution) {
                            HStack {
                                Text("Allow CLI Execution")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Text(
                            "When enabled, characters can run shell commands on your behalf. Every command requires your explicit approval before execution."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        if settings.allowCLIExecution {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                Text(
                                    "Commands run with your user privileges. Only approve commands you understand."
                                )
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Trusted Commands")
                                    .font(.system(size: 13, weight: .medium))
                                Text(
                                    "Commands starting with these prefixes run without asking for confirmation. One per line."
                                )
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)

                                TextField(
                                    "One prefix per line",
                                    text: Binding(
                                        get: {
                                            settings.cliTrustedPrefixes.joined(separator: "\n")
                                        },
                                        set: { newValue in
                                            settings.cliTrustedPrefixes =
                                                newValue
                                                .split(
                                                    separator: "\n",
                                                    omittingEmptySubsequences: false
                                                )
                                                .map {
                                                    String($0).trimmingCharacters(in: .whitespaces)
                                                }
                                                .filter { !$0.isEmpty }
                                        }
                                    ),
                                    axis: .vertical
                                )
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(3...8)
                                .textFieldStyle(.roundedBorder)

                                Text("Examples: ls, cat, pwd, echo, git status, docker ps")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Divider()

                        Toggle(isOn: $settings.datasetLogging) {
                            HStack {
                                Text("Dataset Logging")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Text(
                            "Log agent interactions to ~/.akiapp/datasets/ as JSONL files for fine-tuning. Images are stripped."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        if settings.datasetLogging {
                            Button {
                                let url = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".akiapp/datasets")
                                NSWorkspace.shared.open(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                    Text("Open Datasets Folder")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                // ── Session Memory ──────────────────────
                SettingsSection(title: "SESSION MEMORY") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Max messages per character")
                                .font(.system(size: 13))
                            Spacer()
                            TextField("", value: $settings.sessionMaxMessages, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }

                        HStack {
                            Text("Max age (days)")
                                .font(.system(size: 13))
                            Spacer()
                            TextField("", value: $settings.sessionMaxAgeDays, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }

                        Text(
                            "Messages exceeding these limits are automatically summarized. Older messages are pruned first."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        HStack(spacing: 8) {
                            Button {
                                let url = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".akiapp/sessions")
                                NSWorkspace.shared.open(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                    Text("Open Sessions Folder")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)

                            Button {
                                let url = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".akiapp")
                                NSWorkspace.shared.open(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "house")
                                    Text("Open ~/.akiapp/")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                // ── Games ───────────────────────────────
                SettingsSection(title: "GAMES") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Tic-Tac-Toe Difficulty")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Picker("", selection: $settings.ticTacToeDifficulty) {
                                    ForEach(TicTacToeDifficulty.allCases, id: \.self) {
                                        difficulty in
                                        Text(difficulty.displayName).tag(difficulty)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 220)
                            }
                            Text(
                                "How well the agent plays tic-tac-toe. Hard is unbeatable (perfect minimax)."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var overlaySettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Animation ───────────────────────────
                SettingsSection(title: "ANIMATION") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Display Duration")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(settings.appearanceDuration))s")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.appearanceDuration, in: 1...20, step: 1)
                            Text("How long the card stays visible after the text finishes.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Text Speed")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(settings.textSpeed)) ms")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.textSpeed, in: 10...80, step: 1)
                            Text("Delay per character for the typewriter effect.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // ── Colors ──────────────────────────────
                SettingsSection(title: "COLORS") {
                    VStack(spacing: 12) {
                        ColorRow(label: "Background", hex: $settings.bgColorHex)
                        ColorRow(label: "Border", hex: $settings.borderColorHex)
                        ColorRow(label: "Text", hex: $settings.textColorHex)
                    }
                }

                // ── Layout ──────────────────────────────
                SettingsSection(title: "LAYOUT") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $settings.smallMode) {
                                HStack {
                                    Text("Small Mode")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                }
                            }
                            .toggleStyle(.switch)
                            Text("Scale the card to ~55 % so it fits snugly under the notch.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Notch Clearance")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(settings.notchOffset)) pt")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.notchOffset, in: 10...80, step: 1)
                            Text("Top padding to clear the camera notch.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Horizontal Offset")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(settings.horizontalOffset)) pt")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.horizontalOffset, in: -80...80, step: 1)
                            Text("Shift the card left or right.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // ── Call Suppression ────────────────────
                SettingsSection(title: "CALLS") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            "Suppress triggers when it looks like you're on a call."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        Toggle(isOn: $settings.suppressOnMicActive) {
                            HStack(spacing: 6) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Microphone in use")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: $settings.suppressOnCameraActive) {
                            HStack(spacing: 6) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("Camera in use")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Text(
                            "Either signal is enough to silence triggers. Catches Zoom, Teams, Meet, FaceTime, etc. without maintaining an app list."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                }

                // ── Shape ───────────────────────────────
                SettingsSection(title: "SHAPE") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Corner Radius")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(settings.cornerRadius)) pt")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.cornerRadius, in: 0...40, step: 1)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Border Width")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(String(format: "%.1f pt", settings.borderWidth))
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.borderWidth, in: 0...4, step: 0.5)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Notch Width")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(Int(settings.notchVisualWidth)) pt")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.notchVisualWidth, in: 100...300, step: 1)
                            Text(
                                "Initial card width for the drop animation. Tune to match your notch."
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        }
                    }
                }

                // ── Startup ─────────────────────────────
                SettingsSection(title: "STARTUP") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $settings.startupEnabled) {
                            HStack {
                                Text("Show on launch")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)

                        Text(
                            "Static startup card. If any character has \"Startup greeting\" enabled, that character's LLM-generated greeting will be shown instead."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                        HStack {
                            Text("Name")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 50, alignment: .leading)
                            TextField("Speaker name", text: $settings.startupName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        ColorRow(label: "Name Color", hex: $settings.startupNameColorHex)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Message")
                                .font(.system(size: 13, weight: .medium))
                            TextEditor(text: $settings.startupMessage)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 60, maxHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(.black.opacity(0.15))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.quaternary, lineWidth: 0.5)
                                }
                            Text("Use \\n for line breaks. Shown at app launch.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // ── API Server ──────────────────────────
                SettingsSection(title: "API SERVER") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Port")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            TextField("47037", value: $settings.apiPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("Restart the app after changing the port.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                // ── Compose ─────────────────────────────
                SettingsSection(title: "COMPOSE") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Talk Endpoint")
                            .font(.system(size: 13, weight: .medium))
                        TextField("http://127.0.0.1:8787/talk", text: $settings.talkEndpointURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Text("Composed messages are forwarded as POST to this URL.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                // ── Footer ──────────────────────────────
                VStack(spacing: 12) {
                    Button(action: { settings.resetToDefaults() }) {
                        Text("Reset Overlay to Defaults")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text("API endpoint:  http://127.0.0.1:\(settings.apiPort)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
    }
    // MARK: - CLI Install

    private func checkCLIInstallStatus() {
        cliInstallStatus =
            FileManager.default.fileExists(atPath: "/usr/local/bin/aki")
            ? .installed : .notInstalled
    }

    private func installCLI() {
        cliInstallStatus = .installing

        // Look for the pre-compiled binary first, fall back to the script.
        let sourceURL: URL? =
            Bundle.main.url(forResource: "aki-cli-bin", withExtension: nil)
            ?? Bundle.main.url(forResource: "aki-cli", withExtension: nil)

        guard let sourceURL else {
            cliInstallStatus = .error("CLI not found in app bundle")
            return
        }

        let destination = "/usr/local/bin/aki"

        // Try direct copy first (works if /usr/local/bin is user-writable).
        do {
            if FileManager.default.fileExists(atPath: destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.copyItem(
                at: sourceURL, to: URL(fileURLWithPath: destination))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: destination)
            cliInstallStatus = .installed
            return
        } catch {
            // Expected — sandboxed app can't write to /usr/local/bin.
            // Show a terminal command the user can copy-paste.
        }

        let escapedSource = sourceURL.path.replacingOccurrences(of: " ", with: "\\ ")
        let command = "sudo cp \(escapedSource) \(destination) && sudo chmod +x \(destination)"
        cliInstallStatus = .needsTerminal(command)
    }
}

// MARK: - Tab Button

private struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Settings Helpers

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(.secondary)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                }
        }
    }
}

struct ColorRow: View {
    let label: String
    @Binding var hex: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Text(hex.uppercased())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            ColorPicker(
                "",
                selection: Binding<Color>(
                    get: { Color(hex: hex) },
                    set: { hex = $0.hexString }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(hex.uppercased())")
        .accessibilityValue(hex.uppercased())
    }
}
