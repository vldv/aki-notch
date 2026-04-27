//
//  AkiAppMigration.swift
//  aki-notch-ui
//
//  Centralised one-shot migration that moves data from legacy locations
//  into the canonical ~/.akiapp/ directory.  Call `runIfNeeded()` as early
//  as possible — it is safe to call multiple times (guarded by `hasRun`).
//

import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "AkiAppMigration")

/// Call once at app startup to migrate data from old locations to ~/.akiapp/
enum AkiAppMigration {
    private static var hasRun = false

    static func runIfNeeded() {
        guard !hasRun else { return }
        hasRun = true

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let newDir = homeDir.appendingPathComponent(".akiapp", isDirectory: true)

        // Ensure ~/.akiapp/ exists
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        // ── Migration 1: ~/.aki/ → ~/.akiapp/ ──────────────────────────
        let oldAkiDir = homeDir.appendingPathComponent(".aki", isDirectory: true)
        if fm.fileExists(atPath: oldAkiDir.path),
            !fm.fileExists(atPath: newDir.appendingPathComponent("context.md").path)
        {
            // Move contents individually to avoid overwriting the target dir
            if let contents = try? fm.contentsOfDirectory(
                at: oldAkiDir, includingPropertiesForKeys: nil)
            {
                for item in contents {
                    let dest = newDir.appendingPathComponent(item.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: item, to: dest)
                    }
                }
            }
            // Remove old dir if empty
            try? fm.removeItem(at: oldAkiDir)
            logger.info("Migrated ~/.aki/ contents → ~/.akiapp/")
        }

        // ── Application Support paths ──────────────────────────────────
        guard
            let appSupport = fm.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return }

        // ── Migration 2: characters/ ────────────────────────────────────
        let oldCharsDir =
            appSupport
            .appendingPathComponent("aki-notch-ui", isDirectory: true)
            .appendingPathComponent("characters", isDirectory: true)
        let newCharsDir = newDir.appendingPathComponent("characters", isDirectory: true)
        if fm.fileExists(atPath: oldCharsDir.path),
            !fm.fileExists(atPath: newCharsDir.path)
        {
            try? fm.moveItem(at: oldCharsDir, to: newCharsDir)
            logger.info("Migrated characters/ → ~/.akiapp/characters/")
        }

        // ── Migration 3: providers.json ─────────────────────────────────
        let oldProviders =
            appSupport
            .appendingPathComponent("aki-notch-ui", isDirectory: true)
            .appendingPathComponent("providers.json")
        let newProviders = newDir.appendingPathComponent("providers.json")
        if fm.fileExists(atPath: oldProviders.path),
            !fm.fileExists(atPath: newProviders.path)
        {
            try? fm.moveItem(at: oldProviders, to: newProviders)
            logger.info("Migrated providers.json → ~/.akiapp/providers.json")
        }

        // ── Migration 4: history.json ───────────────────────────────────
        let oldHistory =
            appSupport
            .appendingPathComponent("com.akinotch.app", isDirectory: true)
            .appendingPathComponent("history.json")
        let newHistory = newDir.appendingPathComponent("history.json")
        if fm.fileExists(atPath: oldHistory.path),
            !fm.fileExists(atPath: newHistory.path)
        {
            try? fm.moveItem(at: oldHistory, to: newHistory)
            logger.info("Migrated history.json → ~/.akiapp/history.json")
        }

        // ── Migration 5: sessions/ (from com.akinotch.app) ─────────────
        let oldSessionsDir =
            appSupport
            .appendingPathComponent("com.akinotch.app", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let newSessionsDir = newDir.appendingPathComponent("sessions", isDirectory: true)
        if fm.fileExists(atPath: oldSessionsDir.path) {
            try? fm.createDirectory(at: newSessionsDir, withIntermediateDirectories: true)
            if let sessionFiles = try? fm.contentsOfDirectory(
                at: oldSessionsDir, includingPropertiesForKeys: nil)
            {
                for file in sessionFiles {
                    let dest = newSessionsDir.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: file, to: dest)
                    }
                }
            }
            // Remove old sessions dir if empty
            try? fm.removeItem(at: oldSessionsDir)
            logger.info("Migrated sessions/ → ~/.akiapp/sessions/")
        }

        // ── Migration 6: usage.json & model_pricing.json ────────────────
        let oldComContainer =
            appSupport
            .appendingPathComponent("com.akinotch.app", isDirectory: true)
        let oldUsage = oldComContainer.appendingPathComponent("usage.json")
        let newUsage = newDir.appendingPathComponent("usage.json")
        if fm.fileExists(atPath: oldUsage.path),
            !fm.fileExists(atPath: newUsage.path)
        {
            try? fm.moveItem(at: oldUsage, to: newUsage)
            logger.info("Migrated usage.json → ~/.akiapp/usage.json")
        }
        let oldPricing = oldComContainer.appendingPathComponent("model_pricing.json")
        let newPricing = newDir.appendingPathComponent("model_pricing.json")
        if fm.fileExists(atPath: oldPricing.path),
            !fm.fileExists(atPath: newPricing.path)
        {
            try? fm.moveItem(at: oldPricing, to: newPricing)
            logger.info("Migrated model_pricing.json → ~/.akiapp/model_pricing.json")
        }
    }
}
