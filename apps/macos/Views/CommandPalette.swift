import SwiftUI

/// ⇧⌘P: jump to any session or run a command by typing part of its name.
struct CommandPalette: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("sidebarVisible", store: .merlix) private var sidebarVisible = true
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        var detail = ""
        var session: Session?
        let run: () -> Void
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            TextField("Search sessions and commands", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .focused($focused)
                .onSubmit { run(items) }
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, highlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { highlighted = index; run(items) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
            if items.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func row(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            if let session = item.session {
                StatusIcon(status: session.status, unread: session.unread)
                    .frame(width: 13, height: 13)
            } else {
                Image(systemName: "command")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 13)
            }
            Text(item.title)
                .lineLimit(1)
            Spacer()
            Text(item.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(highlighted ? 0.1 : 0)))
        .contentShape(Rectangle())
    }

    private var allItems: [Item] {
        var items = workspace.orderedSessions.map { session in
            Item(
                id: session.id.uuidString,
                title: session.displayName,
                detail: workspace.project(for: session)?.name ?? "",
                session: session,
                run: { workspace.select(session.id) })
        }
        let selected = workspace.selectedSession
        items += [
            Item(id: "new", title: "New Session", detail: "⌘N") { workspace.addSessionItem() },
            Item(id: "shell", title: "New Shell", detail: "⌥⌘N") { workspace.addSessionItem(command: "") },
            Item(id: "project", title: "Add Project…", detail: "⇧⌘O") { workspace.addProjectWithPanel() },
            Item(id: "sidebar", title: sidebarVisible ? "Hide Sidebar" : "Show Sidebar", detail: "⌃⌘S") {
                sidebarVisible.toggle()
            },
        ]
        if let selected {
            items += [
                Item(id: "find", title: "Find…", detail: "⌘F") { selected.activeSurface?.performBinding("start_search") },
                Item(id: "split-right", title: "Split Right", detail: "⌘D") { workspace.splitSelected(.right) },
                Item(id: "split-down", title: "Split Down", detail: "⇧⌘D") { workspace.splitSelected(.down) },
                Item(id: "equalize", title: "Equalize Splits", detail: "⌃⌘=") { selected.paneHost?.equalize() },
                Item(id: "close", title: "Close Session or Pane", detail: "⌘W") { workspace.closeSelectedSession() },
            ]
        }
        items += [
            Item(id: "reload", title: "Reload Terminal Settings", detail: "⇧⌘,") {
                GhosttyRuntime.shared.reloadConfig()
            },
            Item(id: "settings", title: "Settings…", detail: "⌘,") { workspace.settingsRequest += 1 },
            Item(id: "overrides", title: "Open ghostty.conf") {
                GhosttyRuntime.shared.openOverrides()
            },
        ]
        return items
    }

    private var filtered: [Item] {
        let needle = query.lowercased().filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return allItems }
        return allItems
            .compactMap { item -> (Item, Int)? in
                Self.score(needle, in: "\(item.title) \(item.detail)".lowercased()).map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Characters must appear in order; consecutive and word-start hits score higher.
    private static func score(_ needle: String, in haystack: String) -> Int? {
        var score = 0
        var index = haystack.startIndex
        var previous: String.Index?
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            if let previous, haystack.index(after: previous) == found { score += 3 }
            if found == haystack.startIndex || haystack[haystack.index(before: found)] == " " { score += 2 }
            score += 1
            previous = found
            index = haystack.index(after: found)
        }
        return score
    }

    private func move(_ step: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + step + items.count) % items.count
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(highlighted) else { return }
        let item = items[highlighted]
        dismiss()
        item.run()
    }

    private func dismiss() {
        workspace.paletteVisible = false
        if let view = workspace.selectedSession?.activeSurface {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}
