// OnboardingView.swift — aki-notch-ui

import SwiftUI

// MARK: - Onboarding View

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var apiKey = ""
    @State private var showKeyPlaceholder = true

    var onComplete: () -> Void
    var onAPIKeyProvided: (String) -> Void
    var onOpenSettings: () -> Void

    private let totalSteps = 3
    private let accentColor = Color(hex: "#7FD6FF")
    private let bgColor = Color(hex: "#0A0A0A")
    private let cardBg = Color(hex: "#141414")
    private let subtleGray = Color(hex: "#888888")
    private let borderColor = Color(hex: "#2A2A2A")

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Step content
                Group {
                    switch currentStep {
                    case 0: welcomeStep
                    case 1: apiKeyStep
                    case 2: readyStep
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom bar: step indicators + navigation
                bottomBar
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)
            }
        }
        .frame(width: 480, height: 400)
        .preferredColorScheme(.dark)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("✨ Aki Notch UI ✨")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(accentColor)

            Text("Your MacBook notch just got smarter.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 8) {
                featureRow(
                    "Aki lives in your notch — she can send notifications, chat with you, and keep you company while you work."
                )
            }
            .padding(.horizontal, 48)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Step 2: API Key

    private var apiKeyStep: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("🔑  Set up your AI provider")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Paste your Anthropic API key to power Aki's brain:")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            SecureField("sk-ant-api03-...", text: $apiKey)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .padding(.horizontal, 48)

            VStack(spacing: 6) {
                Text("Don't have one? That's fine — the notch overlay")
                    .font(.system(size: 12))
                    .foregroundStyle(subtleGray)
                Text("and HTTP API work without it.")
                    .font(.system(size: 12))
                    .foregroundStyle(subtleGray)
                Text("You can add keys later in **Settings → Providers**.")
                    .font(.system(size: 12))
                    .foregroundStyle(subtleGray)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("🎉  You're all set!")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 14) {
                shortcutRow(keys: "⌘⇧K", label: "Compose a message to Aki")
                shortcutRow(keys: "HTTP API", label: "curl localhost:47037/overlay")
                shortcutRow(keys: "Menu Bar", label: "Click ✨ for quick actions")
            }
            .padding(.horizontal, 48)
            .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Step indicators
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep ? accentColor : Color.white.opacity(0.2))
                        .frame(width: 7, height: 7)
                        .animation(.easeInOut(duration: 0.25), value: currentStep)
                }
            }

            Spacer()

            // Navigation buttons
            HStack(spacing: 12) {
                switch currentStep {
                case 0:
                    // Welcome — just "Get Started"
                    primaryButton("Get Started →") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = 1
                        }
                    }

                case 1:
                    // API Key — "Skip" + "Next"
                    secondaryButton("Skip") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = 2
                        }
                    }

                    primaryButton("Next →") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onAPIKeyProvided(trimmed)
                        }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = 2
                        }
                    }

                case 2:
                    // Ready — "Open Settings" + "Let's go!"
                    secondaryButton("Open Settings") {
                        onOpenSettings()
                    }

                    primaryButton("Let's go! →") {
                        onComplete()
                    }

                default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Helpers

    private func featureRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .frame(maxWidth: .infinity)
    }

    private func shortcutRow(keys: String, label: String) -> some View {
        HStack(spacing: 14) {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accentColor)
                .frame(width: 80, alignment: .trailing)

            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(accentColor)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingView(
                onComplete: {},
                onAPIKeyProvided: { _ in },
                onOpenSettings: {}
            )
        }
    }
#endif
