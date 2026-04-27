// LiveLogsView.swift — aki-notch-ui

import SwiftUI

// MARK: - Live Logs View

struct LiveLogsView: View {
    @ObservedObject private var logStore = LogStore.shared
    @State private var filterCategory: String? = nil
    @State private var filterLevel: LogEntry.Level? = nil
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                // Category filter
                Menu {
                    Button("All Categories") { filterCategory = nil }
                    Divider()
                    ForEach(logStore.categories.sorted(), id: \.self) { cat in
                        Button(cat) { filterCategory = cat }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11))
                        Text(filterCategory ?? "All")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Level filter
                Menu {
                    Button("All Levels") { filterLevel = nil }
                    Divider()
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        Button(level.rawValue) { filterLevel = level }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                            .font(.system(size: 11))
                        Text(filterLevel?.rawValue ?? "All Levels")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Toggle(isOn: $autoScroll) {
                    Text("Auto-scroll")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Text("\(filteredEntries.count) entries")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button {
                    logStore.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear logs")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Log entries
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No log entries yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("Logs appear here as triggers fire and the agent thinks.")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredEntries) { entry in
                                LogEntryRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: logStore.entries.count) {
                        if autoScroll, let last = filteredEntries.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filteredEntries: [LogEntry] {
        logStore.entries.filter { entry in
            if let cat = filterCategory, entry.category != cat { return false }
            if let lvl = filterLevel, entry.level != lvl { return false }
            return true
        }
    }
}

private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)

            Image(systemName: entry.level.icon)
                .font(.system(size: 9))
                .foregroundStyle(entry.level.color)
                .frame(width: 14)

            Text(entry.category)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
                .font(.system(size: 11))
                .foregroundStyle(entry.level.color.opacity(entry.level == .debug ? 0.7 : 1.0))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(
            entry.level == .error
                ? Color.red.opacity(0.06)
                : entry.level == .warning
                    ? Color.yellow.opacity(0.04)
                    : Color.clear
        )
    }
}
