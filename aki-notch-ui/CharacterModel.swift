//
//  CharacterModel.swift
//  aki-notch-ui
//
//  Swift port of the Python backend's character.py.
//  Loads an AI agent character from a directory on disk:
//
//    characters/<Name>/
//      personality.md     — free-form personality text
//      memories.md        — one memory per line, timestamped
//      accent.txt         — single line hex color like #7FD6FF (optional)
//      faces/             — PNG images named by mood (e.g. angry.png, happy.png)
//

import Combine  // Required for ObservableObject / @Published
import Foundation
import os

private let logger = Logger(subsystem: "com.aki-notch-ui", category: "Character")

// MARK: - Character

/// Observable data model for an AI agent character that lives in the macOS
/// notch overlay.  All published properties drive SwiftUI updates automatically.
final class Character: ObservableObject, Identifiable {

    // MARK: Published Properties

    /// The character's display name (derived from the directory name).
    @Published var name: String

    /// Free-form personality prompt loaded from `personality.md`.
    @Published var personality: String

    /// Accent colour expressed as a hex string (e.g. "#7FD6FF").
    @Published var accentHex: String

    /// Mood name → raw PNG image data.  Keys are lower-cased stems of the
    /// files found in the `faces/` subdirectory.
    @Published var faces: [String: Data]

    // MARK: Non-Published Properties

    /// URL to the `memories.md` file on disk.
    let memoriesURL: URL

    /// URL to the character's root directory.
    let directoryURL: URL

    // MARK: Identifiable

    /// The character's name serves as a stable identity.
    var id: String { name }

    // MARK: Default accent colour

    /// Fallback accent hex used when `accent.txt` is missing or empty.
    static let defaultAccentHex = "#7FD6FF"

    // MARK: Init

    /// Memberwise initialiser — prefer the `load(from:)` factory for normal use.
    init(
        name: String,
        personality: String,
        accentHex: String,
        faces: [String: Data],
        memoriesURL: URL,
        directoryURL: URL
    ) {
        self.name = name
        self.personality = personality
        self.accentHex = accentHex
        self.faces = faces
        self.memoriesURL = memoriesURL
        self.directoryURL = directoryURL
    }

    // MARK: - Factory

    /// Load a character from a directory on disk.
    ///
    /// The directory is expected to contain at least `personality.md`.
    /// Missing files are handled gracefully with sensible defaults.
    static func load(from directory: URL) -> Character {
        let name = directory.lastPathComponent
        let fileManager = FileManager.default

        // --- Personality ---------------------------------------------------
        let personalityURL = directory.appendingPathComponent("personality.md")
        let personality: String = {
            guard fileManager.fileExists(atPath: personalityURL.path) else { return "" }
            do {
                let data = try Data(contentsOf: personalityURL)
                return String(data: data, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines) ?? ""
            } catch {
                logger.warning(
                    "Failed to read personality.md for \(directory.lastPathComponent): \(error.localizedDescription)"
                )
                return ""
            }
        }()

        // --- Accent colour -------------------------------------------------
        let accentURL = directory.appendingPathComponent("accent.txt")
        let accentHex: String = {
            guard fileManager.fileExists(atPath: accentURL.path) else { return defaultAccentHex }
            do {
                let data = try Data(contentsOf: accentURL)
                guard let text = String(data: data, encoding: .utf8) else {
                    return defaultAccentHex
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? defaultAccentHex : trimmed
            } catch {
                logger.warning(
                    "Failed to read accent.txt for \(directory.lastPathComponent): \(error.localizedDescription)"
                )
                return defaultAccentHex
            }
        }()

        // --- Faces ---------------------------------------------------------
        // Map the lower-cased file stem (e.g. "happy") to its raw image data.
        var faces: [String: Data] = [:]
        let facesDir = directory.appendingPathComponent("faces")
        let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]

        if fileManager.fileExists(atPath: facesDir.path) {
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: facesDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for imageURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                {
                    let ext = imageURL.pathExtension.lowercased()
                    guard allowedExtensions.contains(ext) else { continue }

                    let moodName = imageURL.deletingPathExtension()
                        .lastPathComponent
                        .lowercased()

                    do {
                        let imageData = try Data(contentsOf: imageURL)
                        faces[moodName] = imageData
                    } catch {
                        logger.warning(
                            "Failed to load face image '\(moodName)' for \(name): \(error.localizedDescription)"
                        )
                    }
                }
            } catch {
                logger.warning(
                    "Failed to list faces directory for \(name): \(error.localizedDescription)")
            }
        }

        // --- Memories path -------------------------------------------------
        let memoriesURL = directory.appendingPathComponent("memories.md")

        logger.info("Loaded \(name) with \(faces.count) face(s)")

        return Character(
            name: name,
            personality: personality,
            accentHex: accentHex,
            faces: faces,
            memoriesURL: memoriesURL,
            directoryURL: directory
        )
    }

    // MARK: - Computed Properties

    /// Sorted list of available mood / emotion names.
    var faceNames: [String] {
        faces.keys.sorted()
    }

    /// Raw contents of `memories.md`, or an empty string if the file is
    /// missing or unreadable.
    var memories: String {
        guard FileManager.default.fileExists(atPath: memoriesURL.path) else { return "" }
        do {
            let data = try Data(contentsOf: memoriesURL)
            return String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
        } catch {
            logger.warning(
                "Failed to read memories.md for \(self.name): \(error.localizedDescription)")
            return ""
        }
    }

    /// The character's configured default face, falling back to the first available face name.
    var resolvedDefaultFace: String {
        let config = CharacterLLMConfig.load(from: directoryURL)
        if let f = config.defaultFace, faces.keys.contains(f.lowercased()) { return f }
        return faceNames.first ?? "default"
    }

    /// The character's configured coding face (used for CLI confirmations, etc.),
    /// falling back to `resolvedDefaultFace`.
    var resolvedCodingFace: String {
        let config = CharacterLLMConfig.load(from: directoryURL)
        if let f = config.defaultCodingFace, faces.keys.contains(f.lowercased()) { return f }
        return resolvedDefaultFace
    }

    /// Non-empty lines from the memories file.
    var memoryLines: [String] {
        let raw = memories
        guard !raw.isEmpty else { return [] }
        return
            raw
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Human-readable numbered list, e.g.:
    /// ```
    /// 1. [2025-01-01] First memory
    /// 2. [2025-01-02] Second memory
    /// ```
    var numberedMemories: String {
        let lines = memoryLines
        guard !lines.isEmpty else { return "" }
        return lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
    }

    // MARK: - Face Helpers

    /// Returns the base-64 encoded image data for the given emotion, or `nil`
    /// if no matching face exists.  Lookup is case-insensitive.
    func getFaceBase64(_ emotion: String) -> String? {
        let key = emotion.lowercased().trimmingCharacters(in: .whitespaces)
        guard let data = faces[key] else {
            logger.info("Face '\(emotion)' not found for \(self.name)")
            return nil
        }
        return data.base64EncodedString()
    }

    // MARK: - Memory Mutation

    /// Append a new memory entry to `memories.md`.
    func appendMemory(_ content: String) {
        let entry = "\n\(content)\n"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: memoriesURL.path) {
                // Append to the existing file.
                do {
                    let handle = try FileHandle(forWritingTo: memoriesURL)
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } catch {
                    logger.error(
                        "Failed to append memory for \(self.name): \(error.localizedDescription)")
                    Task { @MainActor in
                        LogStore.shared.error(
                            "Character",
                            "Failed to append memory for \(self.name): \(error.localizedDescription)"
                        )
                    }
                }
            } else {
                // Create the file if it doesn't exist yet.
                do {
                    try data.write(to: memoriesURL, options: .atomic)
                } catch {
                    logger.error(
                        "Failed to create memories.md for \(self.name): \(error.localizedDescription)"
                    )
                    Task { @MainActor in
                        LogStore.shared.error(
                            "Character",
                            "Failed to create memories.md for \(self.name): \(error.localizedDescription)"
                        )
                    }
                }
            }
        }
        logger.info("Saved memory for \(self.name)")
        objectWillChange.send()
    }

    /// Edit a memory by its **1-based** line number.
    /// - Returns: A human-readable status message.
    func editMemory(_ lineNumber: Int, _ newContent: String) -> String {
        var lines = memoryLines
        guard lineNumber >= 1, lineNumber <= lines.count else {
            return "Invalid line number \(lineNumber). You have \(lines.count) memories."
        }
        lines[lineNumber - 1] = newContent
        writeMemoryLines(lines)
        objectWillChange.send()
        logger.info("Edited memory #\(lineNumber) for \(self.name)")
        return "Memory #\(lineNumber) updated."
    }

    /// Delete a memory by its **1-based** line number.
    /// - Returns: A human-readable status message.
    func deleteMemory(_ lineNumber: Int) -> String {
        var lines = memoryLines
        guard lineNumber >= 1, lineNumber <= lines.count else {
            return "Invalid line number \(lineNumber). You have \(lines.count) memories."
        }
        let removed = lines.remove(at: lineNumber - 1)
        writeMemoryLines(lines)
        objectWillChange.send()
        let preview = String(removed.prefix(80))
        logger.info("Deleted memory #\(lineNumber) for \(self.name): \(preview)")
        return "Memory #\(lineNumber) deleted."
    }

    // MARK: - Persistence Helpers

    /// Overwrite `memories.md` with the supplied lines.
    private func writeMemoryLines(_ lines: [String]) {
        let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: memoriesURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error(
                "Failed to write memories.md for \(self.name): \(error.localizedDescription)")
            Task { @MainActor in
                LogStore.shared.error(
                    "Character",
                    "Failed to write memories for \(self.name): \(error.localizedDescription)")
            }
        }
    }

    /// Write the current `personality` string back to `personality.md`.
    func savePersonality() {
        let url = directoryURL.appendingPathComponent("personality.md")
        do {
            try personality.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Saved personality for \(self.name)")
        } catch {
            logger.error(
                "Failed to save personality for \(self.name): \(error.localizedDescription)")
            Task { @MainActor in
                LogStore.shared.error(
                    "Character",
                    "Failed to save personality for \(self.name): \(error.localizedDescription)")
            }
        }
    }

    /// Write the current `accentHex` string back to `accent.txt`.
    func saveAccentHex() {
        let url = directoryURL.appendingPathComponent("accent.txt")
        do {
            try accentHex.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Saved accent hex for \(self.name)")
        } catch {
            logger.error(
                "Failed to save accent hex for \(self.name): \(error.localizedDescription)")
            Task { @MainActor in
                LogStore.shared.error(
                    "Character",
                    "Failed to save accent hex for \(self.name): \(error.localizedDescription)")
            }
        }
    }
}
