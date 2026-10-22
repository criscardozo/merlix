import SwiftUI

/// What hiding the sidebar shows: tabs for every session, or the selected
/// session alone. Picked in Settings.
enum HiddenSidebarStyle: String {
    case tabs
    case focus

    static let key = "hiddenSidebarStyle"
}

/// Every session as a tab across the title bar, in sidebar order. Drag a tab to
/// reorder; the sidebar follows.
struct SessionTabs: View {
    @Environment(Workspace.self) private var workspace
    @State private var dragging: UUID?
    @State private var mark: (id: UUID, before: Bool)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(workspace.orderedSessions) { session in
                    SessionTab(session: session, selected: session.id == workspace.selectedSessionID)
                        .overlay(alignment: .leading) { line(session.id, before: true) }
                        .overlay(alignment: .trailing) { line(session.id, before: false) }
                        .onTapGesture { workspace.select(session.id) }
                        .onDrag {
                            dragging = session.id
                            return NSItemProvider(object: session.id.uuidString as NSString)
                        }
                        .onDrop(of: [.plainText], delegate: TabDropDelegate(
                            target: session.id, dragging: dragging, mark: $mark,
                            perform: { before in
                                if let dragging { workspace.moveTab(dragging, nextTo: session.id, before: before) }
                                dragging = nil
                            }))
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func line(_ id: UUID, before: Bool) -> some View {
        if let mark, mark.id == id, mark.before == before {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2)
                .padding(.vertical, 4)
                .offset(x: before ? -2 : 2)
                .allowsHitTesting(false)
        }
    }
}

private struct SessionTab: View {
    @Environment(Workspace.self) private var workspace
    let session: Session
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let project = workspace.project(for: session)
        HStack(spacing: 6) {
            if let project { ProjectIconView(project: project, size: 14) }
            Text(title(project))
                .fontWeight(session.unread ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            ZStack {
                StatusIcon(status: session.status, unread: session.unread)
                    .opacity(hovering ? 0 : 1)
                if hovering {
                    Button {
                        workspace.requestClose(session, processAlive: session.surfaceView?.needsConfirmClose ?? false)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close Session")
                }
            }
            .frame(width: 13, height: 13)
        }
        .font(.system(size: 12))
        .opacity(session.isRunning || selected ? 1 : 0.6)
        .padding(.horizontal, 10)
        .frame(minWidth: 110, maxWidth: 200)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(selected ? 0.12 : hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project?.displayPath ?? "")
    }

    /// The project's name; later sessions of a project add their own.
    private func title(_ project: Project?) -> String {
        guard let project else { return session.displayName }
        let first = workspace.sessions(in: project).first?.id == session.id
        return first ? project.name : "\(project.name) · \(session.displayName)"
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let dragging: UUID?
    @Binding var mark: (id: UUID, before: Bool)?
    let perform: (_ before: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil && dragging != target }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        // Tabs are at least 110 pt wide; the left half drops before.
        mark = (target, info.location.x < 55)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if mark?.id == target { mark = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let before = mark?.before ?? (info.location.x < 55)
        mark = nil
        guard validateDrop(info: info) else { return false }
        perform(before)
        return true
    }
}

/// A small drawing of each layout for Settings.
struct LayoutPreview: View {
    enum Kind { case sidebar, tabs, focus }
    let kind: Kind

    private static let colours: [Color] = [
        Color(red: 0.50, green: 0.35, blue: 0.94), Color(red: 1.00, green: 0.54, blue: 0.36),
        Color(red: 0.00, green: 0.71, blue: 0.85), Color(red: 0.96, green: 0.62, blue: 0.04),
    ]

    var body: some View {
        let window = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack(alignment: .topLeading) {
            window.fill(.background.secondary)
            HStack(spacing: 0) {
                if kind == .sidebar {
                    VStack(alignment: .leading, spacing: 5) {
                        dots.padding(.bottom, 4)
                        ForEach(0..<4, id: \.self) { index in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(Self.colours[index]).frame(width: 8, height: 8)
                                Capsule().fill(.secondary.opacity(index == 0 ? 0.7 : 0.35)).frame(width: 26, height: 4)
                            }
                            .padding(3)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(index == 0 ? 0.1 : 0)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 9)
                    .frame(width: 62)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        if kind != .sidebar { dots.padding(.trailing, 4) }
                        if kind == .tabs {
                            ForEach(0..<3, id: \.self) { index in
                                HStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: 1.5).fill(Self.colours[index]).frame(width: 6, height: 6)
                                    Capsule().fill(.white.opacity(index == 0 ? 0.7 : 0.35)).frame(width: 16, height: 3)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(index == 0 ? 0.15 : 0)))
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 1.5).fill(Self.colours[0]).frame(width: 6, height: 6)
                            Capsule().fill(.white.opacity(0.7)).frame(width: 30, height: 3)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .padding(.top, 4)
                    .frame(height: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach([44, 30, 52, 22], id: \.self) { width in
                            Capsule().fill(.white.opacity(0.3)).frame(width: CGFloat(width), height: 3)
                        }
                    }
                    .padding(8)
                    Spacer(minLength: 0)
                }
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: kind == .sidebar ? 5 : 0, bottomLeadingRadius: kind == .sidebar ? 5 : 8,
                        bottomTrailingRadius: kind == .sidebar ? 5 : 8, topTrailingRadius: kind == .sidebar ? 5 : 8,
                        style: .continuous)
                        .fill(Color(white: 0.12)))
                .padding(kind == .sidebar ? EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 6) : EdgeInsets())
            }
        }
        .clipShape(window)
        .overlay(window.strokeBorder(.separator))
        .frame(width: 150, height: 98)
    }

    private var dots: some View {
        HStack(spacing: 3) {
            Circle().fill(.red.opacity(0.8))
            Circle().fill(.yellow.opacity(0.8))
            Circle().fill(.green.opacity(0.8))
        }
        .frame(width: 22, height: 6)
    }
}
