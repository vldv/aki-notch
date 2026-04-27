// ActivationView.swift — aki-notch-ui

import SwiftUI

struct ActivationView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var licenseKey = ""
    @State private var isActivating = false
    @State private var errorMessage: String?
    var onDismiss: (() -> Void)?

    private let accentColor = Color(hex: "#7FD6FF")
    private let bgColor = Color(hex: "#0A0A0A")
    private let cardBg = Color(hex: "#141414")
    private let subtleGray = Color(hex: "#888888")
    private let borderColor = Color(hex: "#2A2A2A")

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.top, 28)
                    .padding(.bottom, 20)

                // Status badge
                statusBadge
                    .padding(.bottom, 24)

                // Main content
                switch licenseManager.status {
                case .active:
                    activeLicenseContent
                default:
                    activationForm
                }

                Spacer()

                // Bottom bar
                bottomBar
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 400, height: 300)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("License")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Manage your Aki Notch UI license")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(subtleGray)
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(licenseManager.statusDescription)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.12))
                .overlay(
                    Capsule()
                        .stroke(statusColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var statusColor: Color {
        switch licenseManager.status {
        case .active:
            return .green
        case .trial:
            return accentColor
        case .expired:
            return .orange
        case .invalid:
            return .red
        }
    }

    // MARK: - Activation Form

    private var activationForm: some View {
        VStack(spacing: 14) {
            // License key field
            HStack(spacing: 0) {
                TextField("Paste your license key…", text: $licenseKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .disabled(isActivating)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        errorMessage != nil ? Color.red.opacity(0.5) : borderColor, lineWidth: 1)
            )
            .padding(.horizontal, 32)

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Activate button
            Button {
                Task { await activateLicense() }
            } label: {
                HStack(spacing: 6) {
                    if isActivating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    }
                    Text(isActivating ? "Validating…" : "Activate")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isActivating
                                ? accentColor.opacity(0.4)
                                : accentColor)
                )
            }
            .buttonStyle(.plain)
            .disabled(
                licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating
            )
            .padding(.horizontal, 32)
        }
        .onChange(of: licenseKey) {
            errorMessage = nil
        }
    }

    // MARK: - Active License Content

    private var activeLicenseContent: some View {
        VStack(spacing: 16) {
            // Masked key display
            if let key = licenseManager.storedKey {
                let masked = maskKey(key)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))

                    Text(masked)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.green.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.green.opacity(0.15), lineWidth: 1)
                        )
                )
            }

            // Deactivate button
            Button {
                licenseManager.deactivate()
                licenseKey = ""
                errorMessage = nil
            } label: {
                Text("Deactivate License")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.red.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Buy license link
            Button {
                NSWorkspace.shared.open(
                    URL(string: "https://buy.stripe.com/7sY3cx1Nde0X1gtaXZ5J600")!)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cart")
                        .font(.system(size: 11))
                    Text("Buy License")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(accentColor.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .stroke(accentColor.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Dismiss button
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Text("Close")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func activateLicense() async {
        errorMessage = nil
        isActivating = true

        let success = await licenseManager.activate(key: licenseKey)

        isActivating = false

        if success {
            licenseKey = ""
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                errorMessage = "Invalid license key. Please check and try again."
            }
        }
    }

    // MARK: - Helpers

    private func maskKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 {
            return trimmed
        }
        let prefix = String(trimmed.prefix(4))
        let suffix = String(trimmed.suffix(4))
        return "\(prefix)••••••••\(suffix)"
    }
}

// MARK: - Preview

#if DEBUG
    struct ActivationView_Previews: PreviewProvider {
        static var previews: some View {
            ActivationView(licenseManager: LicenseManager())
        }
    }
#endif
