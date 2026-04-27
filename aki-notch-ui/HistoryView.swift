// HistoryView.swift — aki-notch-ui
//
//  Retro / 8-bit styled conversation history view.
//  Renders the exchange between the user and characters as an iMessage-like
//  thread, with character messages on the left and user messages on the right.
//  Character face avatars are shown alongside each message when available.
//

import AppKit
import SwiftUI

// MARK: - History View

struct HistoryView: View {
    @ObservedObject private var historyStore = HistoryStore.shared
    @ObservedObject var characterStore: CharacterStore
    @State private var filterCharacter: String? = nil
    @State private var searchText: String = ""

    private let pixelFont = "Press Start 2P"

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                // Character filter
                Menu {
                    Button("All Characters") { filterCharacter = nil }
                    Divider()
                    ForEach(historyStore.characterNames, id: \.self) { name in
                        Button(name) { filterCharacter = name }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.system(size: 11))
                        Text(filterCharacter ?? "All")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("Search…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(6)
                .frame(maxWidth: 180)

                Spacer()

                Text("\(filteredEntries.count) messages")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button {
                    historyStore.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear history")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Message thread
            if filteredEntries.isEmpty {
                emptyState
            } else {
                messageThread
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("💬")
                .font(.system(size: 36))

            Text("No messages yet")
                .font(.custom(pixelFont, size: 10))
                .foregroundStyle(.tertiary)

            Text("Exchanges with characters\nwill appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message Thread

    private var messageThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groupedByDay, id: \.day) { group in
                        daySeparator(group.day)
                            .id("day-\(group.day)")

                        ForEach(group.entries) { entry in
                            MessageBubble(
                                entry: entry,
                                pixelFont: pixelFont,
                                faceImage: faceImage(for: entry)
                            )
                            .id(entry.id)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: historyStore.entries.count) {
                if let last = filteredEntries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                // Scroll to the bottom on first appearance
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let last = filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Face Image Lookup

    /// Resolve the face image for a history entry by looking up the character's
    /// face data from the CharacterStore using the stored face/mood name.
    private func faceImage(for entry: HistoryEntry) -> NSImage? {
        guard entry.type == .characterMessage else { return nil }

        // Find the character by sender name.
        guard
            let character = characterStore.characters.first(where: {
                $0.name == entry.senderName
            })
        else { return nil }

        // Look up the face by mood name if available.
        if let faceName = entry.faceName,
            let data = character.faces[faceName.lowercased()],
            let image = NSImage(data: data)
        {
            return image
        }

        // Fallback: use the first available face for this character.
        if let firstFaceData = character.faces.values.first,
            let image = NSImage(data: firstFaceData)
        {
            return image
        }

        return nil
    }

    // MARK: - Day Separator

    private func daySeparator(_ day: String) -> some View {
        HStack {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            Text(day)
                .font(.custom(pixelFont, size: 7))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .padding(.horizontal, 8)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    // MARK: - Grouping & Filtering

    private var filteredEntries: [HistoryEntry] {
        historyStore.entries.filter { entry in
            // Character filter: when a specific character is selected, show
            // that character's messages AND all user messages (for context).
            if let character = filterCharacter {
                let isRelevant =
                    entry.senderName == character
                    || entry.type == .userMessage
                    || entry.type == .system
                if !isRelevant { return false }
            }

            // Text search
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let matchesMessage = entry.message.lowercased().contains(query)
                let matchesSender = entry.senderName.lowercased().contains(query)
                if !matchesMessage && !matchesSender { return false }
            }

            return true
        }
    }

    private struct DayGroup {
        let day: String
        let entries: [HistoryEntry]
    }

    private var groupedByDay: [DayGroup] {
        let grouped = Dictionary(grouping: filteredEntries) { $0.dayStamp }
        return
            grouped
            .map { DayGroup(day: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                guard let l = lhs.entries.first?.date, let r = rhs.entries.first?.date else {
                    return false
                }
                return l < r
            }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let entry: HistoryEntry
    let pixelFont: String
    /// The resolved face NSImage for this entry (nil for user/system messages
    /// or when no face is available).
    let faceImage: NSImage?

    /// Avatar thumbnail size.
    private let avatarSize: CGFloat = 32

    var body: some View {
        switch entry.type {
        case .userMessage:
            userBubble
        case .characterMessage:
            characterBubble
        case .system:
            systemBubble
        }
    }

    // MARK: User Bubble (right-aligned)

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.message)
                    .font(.custom(pixelFont, size: 8))
                    .foregroundStyle(.white)
                    .lineSpacing(6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        BubbleShape(isUser: true)
                            .fill(Color.blue.opacity(0.75))
                    )
                    .overlay(
                        BubbleShape(isUser: true)
                            .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.message, forType: .string)
                        }
                    }

                Text(entry.timestamp)
                    .font(.custom(pixelFont, size: 6))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    // MARK: Character Bubble (left-aligned, with face avatar)

    private var characterBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            // Face avatar
            faceAvatar

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.senderName)
                    .font(.custom(pixelFont, size: 7))
                    .foregroundColor(Color(hex: entry.accentColorHex))

                Text(entry.message)
                    .font(.custom(pixelFont, size: 8))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        BubbleShape(isUser: false)
                            .fill(Color(hex: entry.accentColorHex).opacity(0.12))
                    )
                    .overlay(
                        BubbleShape(isUser: false)
                            .strokeBorder(
                                Color(hex: entry.accentColorHex).opacity(0.25),
                                lineWidth: 1
                            )
                    )
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.message, forType: .string)
                        }
                    }

                Text(entry.timestamp)
                    .font(.custom(pixelFont, size: 6))
                    .foregroundStyle(.quaternary)
            }

            Spacer(minLength: 60)
        }
    }

    // MARK: Face Avatar

    @ViewBuilder
    private var faceAvatar: some View {
        if let image = faceImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)  // Pixel-perfect scaling — keeps the 8-bit look
                .aspectRatio(contentMode: .fill)
                .frame(width: avatarSize, height: avatarSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            Color(hex: entry.accentColorHex).opacity(0.4),
                            lineWidth: 1
                        )
                )
        } else {
            // Fallback: colored square with first letter of sender name
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: entry.accentColorHex).opacity(0.2))
                .frame(width: avatarSize, height: avatarSize)
                .overlay(
                    Text(String(entry.senderName.prefix(1)).uppercased())
                        .font(.custom(pixelFont, size: 12))
                        .foregroundColor(Color(hex: entry.accentColorHex))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            Color(hex: entry.accentColorHex).opacity(0.3),
                            lineWidth: 1
                        )
                )
        }
    }

    // MARK: System Bubble (centered)

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(entry.message)
                .font(.custom(pixelFont, size: 7))
                .foregroundStyle(.secondary.opacity(0.6))
                .italic()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.04))
                )
            Spacer()
        }
    }
}

// MARK: - Bubble Shape

/// Pixel-art-inspired chat bubble with a small notch on the bottom corner.
/// Uses slightly rounded corners for a retro feel without being fully round.
private struct BubbleShape: InsettableShape {
    let isUser: Bool
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 4  // Small corner radius — pixel-art vibe
        let notchSize: CGFloat = 6
        let inset = rect.insetBy(dx: insetAmount, dy: insetAmount)

        var path = Path()

        if isUser {
            // User bubble: notch on bottom-right
            path.addRoundedRect(
                in: CGRect(
                    x: inset.minX,
                    y: inset.minY,
                    width: inset.width - notchSize / 2,
                    height: inset.height
                ),
                cornerSize: CGSize(width: r, height: r)
            )
            // Small triangle notch
            path.move(to: CGPoint(x: inset.maxX - notchSize, y: inset.maxY - notchSize))
            path.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.maxX - notchSize, y: inset.maxY))
            path.closeSubpath()
        } else {
            // Character bubble: notch on bottom-left
            path.addRoundedRect(
                in: CGRect(
                    x: inset.minX + notchSize / 2,
                    y: inset.minY,
                    width: inset.width - notchSize / 2,
                    height: inset.height
                ),
                cornerSize: CGSize(width: r, height: r)
            )
            // Small triangle notch
            path.move(to: CGPoint(x: inset.minX + notchSize, y: inset.maxY - notchSize))
            path.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
            path.addLine(to: CGPoint(x: inset.minX + notchSize, y: inset.maxY))
            path.closeSubpath()
        }

        return path
    }

    func inset(by amount: CGFloat) -> BubbleShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}
