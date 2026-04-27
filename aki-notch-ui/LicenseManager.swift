// LicenseManager.swift — aki-notch-ui

import Combine
import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "License")

@MainActor
final class LicenseManager: ObservableObject {

    // MARK: - Published State

    enum LicenseStatus: Equatable {
        case trial(daysRemaining: Int)
        case active(key: String)
        case expired  // trial ended, no valid license
        case invalid  // license key was rejected
    }

    @Published var status: LicenseStatus = .trial(daysRemaining: 5)

    // MARK: - Constants

    static let trialDays = 5
    private static let keychainKey = "license.key"
    private static let trialStartKey = "license.trialStartDate"
    private static let trialStartKeychainKey = "license.trialStart"

    // Ed25519 public key (raw 32 bytes, base64-encoded).
    private static let publicKeyBase64 = "a4Vf9okrnH3rLZfkXYQa/oirDzh607rlo9uCBXJO6o0="

    // MARK: - Init

    init() {
        refreshStatus()
    }

    // MARK: - Trial Management

    /// Returns the trial start date, creating one on first access.
    /// Stored in both UserDefaults and Keychain for tamper resistance.
    private var trialStartDate: Date {
        let ud = UserDefaults.standard

        // Check Keychain first (tamper-resistant)
        if let keychainValue = KeychainHelper.load(key: Self.trialStartKeychainKey),
            let timestamp = Double(keychainValue)
        {
            let keychainDate = Date(timeIntervalSince1970: timestamp)
            // Ensure UserDefaults is in sync
            if ud.object(forKey: Self.trialStartKey) == nil {
                ud.set(keychainDate, forKey: Self.trialStartKey)
            }
            return keychainDate
        }

        // Check UserDefaults
        if let stored = ud.object(forKey: Self.trialStartKey) as? Date {
            // Persist to Keychain for tamper resistance
            KeychainHelper.save(
                key: Self.trialStartKeychainKey, value: String(stored.timeIntervalSince1970))
            return stored
        }

        // First launch — create trial start
        let now = Date()
        ud.set(now, forKey: Self.trialStartKey)
        KeychainHelper.save(
            key: Self.trialStartKeychainKey, value: String(now.timeIntervalSince1970))
        return now
    }

    private var trialDaysRemaining: Int {
        let elapsed =
            Calendar.current.dateComponents([.day], from: trialStartDate, to: Date()).day ?? 0
        return max(0, Self.trialDays - elapsed)
    }

    private var isTrialActive: Bool {
        trialDaysRemaining > 0
    }

    // MARK: - License Key Management

    var storedKey: String? {
        KeychainHelper.load(key: Self.keychainKey)
    }

    func activate(key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Validate signature locally (offline)
        if validateSignature(key: trimmed) {
            KeychainHelper.save(key: Self.keychainKey, value: trimmed)
            status = .active(key: trimmed)
            logger.info("License activated successfully")
            return true
        } else {
            // Restore previous status (trial may still be active)
            refreshStatus()
            logger.warning("License activation failed — invalid signature")
            return false
        }
    }

    func deactivate() {
        KeychainHelper.delete(key: Self.keychainKey)
        refreshStatus()
        logger.info("License deactivated")
    }

    // MARK: - Status Resolution

    func refreshStatus() {
        if let key = storedKey {
            if validateSignature(key: key) {
                status = .active(key: key)
            } else {
                // Stored key is no longer valid — remove it and fall back
                logger.warning("Stored license key has invalid signature — removing")
                KeychainHelper.delete(key: Self.keychainKey)
                if isTrialActive {
                    status = .trial(daysRemaining: trialDaysRemaining)
                } else {
                    status = .expired
                }
            }
        } else if isTrialActive {
            status = .trial(daysRemaining: trialDaysRemaining)
        } else {
            status = .expired
        }
    }

    // MARK: - Ed25519 Signature Verification

    /// Validates a license key by verifying its Ed25519 signature.
    ///
    /// Key format: `{base64url_payload}.{base64url_signature}`
    /// - Payload is JSON: `{"e":"user@example.com","t":1234567890}`
    /// - Signature is Ed25519 over the raw payload bytes
    private func validateSignature(key: String) -> Bool {
        let parts = key.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            logger.warning("License key format invalid — expected payload.signature")
            return false
        }

        let payloadPart = String(parts[0])
        let signaturePart = String(parts[1])

        guard let payloadData = Self.base64URLDecode(payloadPart) else {
            logger.warning("License key payload is not valid base64url")
            return false
        }

        guard let signatureData = Self.base64URLDecode(signaturePart) else {
            logger.warning("License key signature is not valid base64url")
            return false
        }

        guard let publicKeyData = Data(base64Encoded: Self.publicKeyBase64) else {
            logger.error("Ed25519 public key constant is not valid base64")
            return false
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            let isValid = publicKey.isValidSignature(signatureData, for: payloadData)
            if !isValid {
                logger.warning("Ed25519 signature verification failed")
            }
            return isValid
        } catch {
            logger.error("Failed to create Ed25519 public key: \(error.localizedDescription)")
            return false
        }
    }

    /// Decodes a base64url-encoded string to `Data`.
    /// Converts base64url characters to standard base64 and adds padding as needed.
    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding if necessary
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    // MARK: - Convenience

    var isLicensed: Bool {
        switch status {
        case .active: return true
        case .trial: return true  // trial counts as licensed
        case .expired, .invalid: return false
        }
    }

    var statusDescription: String {
        switch status {
        case .trial(let days): return "\(days) day\(days == 1 ? "" : "s") left in trial"
        case .active: return "Licensed"
        case .expired: return "Trial expired"
        case .invalid: return "Invalid license"
        }
    }
}
