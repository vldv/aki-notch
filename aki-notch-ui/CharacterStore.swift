//
//  CharacterStore.swift
//  aki-notch-ui
//
//  Manages persistence and CRUD for AI agent characters on disk.
//  Characters live under ~/.akiapp/characters/.
//

import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "CharacterStore")

@MainActor
final class CharacterStore: ObservableObject {

    // MARK: - Published State

    @Published var characters: [Character] = []

    // MARK: - Storage Location

    /// Root directory for all character data on disk.
    let baseDirectory: URL

    // MARK: - Init

    init() {
        // Run migration before reading from ~/.akiapp/
        AkiAppMigration.runIfNeeded()

        // ~/.akiapp/characters/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.baseDirectory =
            homeDir
            .appendingPathComponent(".akiapp", isDirectory: true)
            .appendingPathComponent("characters", isDirectory: true)

        // Ensure the base directory exists before doing anything else.
        do {
            try FileManager.default.createDirectory(
                at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create base directory: \(error.localizedDescription)")
            LogStore.shared.error(
                "CharacterStore", "Failed to create base directory: \(error.localizedDescription)")
        }

        seedDefaultsIfNeeded()
        loadAll()
    }

    // MARK: - Load

    /// Scans `baseDirectory` for subdirectories and loads each one as a `Character`.
    func loadAll() {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.error(
                "Could not list contents of \(self.baseDirectory.path): \(error.localizedDescription)"
            )
            LogStore.shared.error(
                "CharacterStore",
                "Could not list characters directory: \(error.localizedDescription)")
            return
        }

        characters =
            contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Character.load(from: $0) }

        logger.info("Loaded \(self.characters.count) character(s)")
    }

    // MARK: - Create

    /// Creates a new character directory with scaffolding files and returns the loaded `Character`.
    /// Returns `nil` if a character with that name already exists or the write fails.
    @discardableResult
    func createCharacter(name: String) -> Character? {
        let fm = FileManager.default
        let charDir = baseDirectory.appendingPathComponent(name, isDirectory: true)

        guard !fm.fileExists(atPath: charDir.path) else {
            logger.info("Character '\(name)' already exists — skipping create")
            return nil
        }

        do {
            // Create directory structure: <Name>/ and <Name>/faces/
            try fm.createDirectory(
                at: charDir.appendingPathComponent("faces", isDirectory: true),
                withIntermediateDirectories: true)

            // Scaffold empty personality & memories files and default accent
            try "".write(
                to: charDir.appendingPathComponent("personality.md"), atomically: true,
                encoding: .utf8)
            try "".write(
                to: charDir.appendingPathComponent("memories.md"), atomically: true, encoding: .utf8
            )
            try Character.defaultAccentHex.write(
                to: charDir.appendingPathComponent("accent.txt"),
                atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to create character '\(name)': \(error.localizedDescription)")
            LogStore.shared.error(
                "CharacterStore",
                "Failed to create character '\(name)': \(error.localizedDescription)")
            return nil
        }

        let character = Character.load(from: charDir)
        characters.append(character)
        return character
    }

    // MARK: - Delete

    /// Removes a character's directory from disk and from the in-memory array.
    func deleteCharacter(_ character: Character) {
        do {
            try FileManager.default.removeItem(at: character.directoryURL)
        } catch {
            logger.error("Failed to delete '\(character.name)': \(error.localizedDescription)")
            LogStore.shared.error(
                "CharacterStore",
                "Failed to delete '\(character.name)': \(error.localizedDescription)")
        }
        characters.removeAll { $0.id == character.id }
    }

    // MARK: - Face Management

    /// Writes image data to `<Name>/faces/<mood>.png` and updates the character in memory.
    func importFace(
        for character: Character, named mood: String, imageData: Data, fileExtension: String = "png"
    ) {
        let facesDir = character.directoryURL.appendingPathComponent("faces", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: facesDir, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "Failed to create faces directory for \(character.name): \(error.localizedDescription)"
            )
            LogStore.shared.error(
                "CharacterStore",
                "Failed to create faces directory for \(character.name): \(error.localizedDescription)"
            )
        }

        let fileURL = facesDir.appendingPathComponent(
            "\(mood.lowercased()).\(fileExtension.lowercased())")
        do {
            try imageData.write(to: fileURL, options: .atomic)
            character.faces[mood.lowercased()] = imageData
            logger.info("Imported face '\(mood)' for \(character.name)")
        } catch {
            logger.error("Failed to import face '\(mood)': \(error.localizedDescription)")
            LogStore.shared.error(
                "CharacterStore",
                "Failed to import face '\(mood)' for \(character.name): \(error.localizedDescription)"
            )
        }
    }

    /// Deletes a face image from disk and removes it from the character's in-memory dictionary.
    func deleteFace(for character: Character, named mood: String) {
        let key = mood.lowercased()
        let facesDir = character.directoryURL
            .appendingPathComponent("faces", isDirectory: true)

        // Search for the actual file with any supported extension
        let supportedExtensions = ["png", "jpg", "jpeg", "webp", "gif"]
        var deleted = false
        for ext in supportedExtensions {
            let fileURL = facesDir.appendingPathComponent("\(key).\(ext)")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    deleted = true
                } catch {
                    logger.error("Failed to delete face '\(mood)': \(error.localizedDescription)")
                    LogStore.shared.error(
                        "CharacterStore",
                        "Failed to delete face '\(mood)' for \(character.name): \(error.localizedDescription)"
                    )
                }
            }
        }
        if !deleted {
            logger.warning("No face file found on disk for '\(mood)' of \(character.name)")
        }
        character.faces.removeValue(forKey: key)
    }

    // MARK: - Default Seeding

    /// Characters to seed for new users. Others in DefaultCharacters/ are kept in the
    /// repo for the developer but won't ship to customers.
    private static let seedCharacterNames: Set<String> = ["Aki"]

    /// Copies bundled default characters into the characters directory
    /// when it is empty or freshly created. Silently skips if bundle resources aren't present.
    func seedDefaultsIfNeeded() {
        let fm = FileManager.default

        // Only seed when the characters directory is empty.
        let existing: [String]
        do {
            existing = try fm.contentsOfDirectory(atPath: baseDirectory.path)
        } catch {
            logger.error(
                "Failed to list characters directory for seeding: \(error.localizedDescription)")
            return
        }
        let hasCharacters = existing.contains { !$0.hasPrefix(".") }
        guard !hasCharacters else { return }

        // Locate the bundled DefaultCharacters folder.
        guard
            let bundleDefaultsURL = Bundle.main.resourceURL?.appendingPathComponent(
                "DefaultCharacters"),
            fm.fileExists(atPath: bundleDefaultsURL.path)
        else {
            // Bundle resources haven't been added yet — nothing to seed.
            return
        }

        let defaultNames: [String]
        do {
            defaultNames = try fm.contentsOfDirectory(atPath: bundleDefaultsURL.path)
        } catch {
            logger.warning(
                "Failed to list bundled DefaultCharacters: \(error.localizedDescription)")
            return
        }

        for name in defaultNames
        where !name.hasPrefix(".") && Self.seedCharacterNames.contains(name) {
            let src = bundleDefaultsURL.appendingPathComponent(name)
            let dst = baseDirectory.appendingPathComponent(name)
            do {
                try fm.copyItem(at: src, to: dst)
                logger.info("Seeded default character '\(name)'")
            } catch {
                logger.error("Failed to seed '\(name)': \(error.localizedDescription)")
            }
        }
    }
}
