import SwiftUI
import UniformTypeIdentifiers

/// Groups as small labels, each project as one row with its icon. A project's
/// first session is the row itself; any further sessions sit indented below it.
struct SidebarView: View {
    @Environment(Workspace.self) private var workspace
    @State private var renaming: Session?
    @State private var renamingGroup: ProjectGroup?
    @State private var text = ""
    /// What is being dragged, and where it would land. Drags stay inside the
    /// sidebar, so the payload is kept here rather than read back from the pasteboard.
    @State private var dragging: DragItem?
    @State private var dropMark: DropMark?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                NewSessionMenu()
            }
            .padding(.horizontal, 12)
            .frame(height: titleBarHeight)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let loose = workspace.projects(in: nil)
                    if !loose.isEmpty || (!workspace.groups.isEmpty && dragging != nil) {
                        if !workspace.groups.isEmpty {
                            GroupHeader(title: "Projects", projects: loose, collapsed: nil, toggle: nil) {
                                newSessionMenus(in: nil)
                                Button("Import Project…") { workspace.addProjectWithPanel(into: nil) }
                                Button("New Group…") { workspace.promptForNewGroup() }
                            }
                                .overlay(alignment: .bottom) { mark(.header(nil), before: false) }
                                .onDrop(of: [.merlixItem], delegate: dropDelegate(.header(nil), height: Self.headerHeight))
                        }
                        ForEach(loose) { projectItem($0) }
                    }
                    ForEach(workspace.groups) { group in
                        let projects = workspace.projects(in: group)
                        GroupHeader(
                            title: group.name, projects: projects, collapsed: group.isCollapsed,
                            toggle: { withAnimation(.smooth(duration: 0.2)) { workspace.toggleCollapsed(group) } }
                        ) {
                            groupMenu(group)
                        }
                            .overlay(alignment: .top) { mark(.header(group.id), before: true) }
                            .overlay(alignment: .bottom) { mark(.header(group.id), before: false) }
                            .contextMenu { groupMenu(group) }
                            .onDrag {
                                dragging = .group(group.id)
                                return NSItemProvider.merlixItem()
                            }
                            .onDrop(of: [.merlixItem], delegate: dropDelegate(.header(group.id), height: Self.headerHeight))
                        if !group.isCollapsed {
                            ForEach(projects) { projectItem($0) }
                        }
                    }
                    if workspace.projects.isEmpty {
                        Button("Add Project…") { workspace.addProjectWithPanel() }
                            .buttonStyle(.link)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                // At least as tall as the sidebar, so empty space below the
                // rows takes a right-click; rows and labels keep their own menus.
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                .contentShape(Rectangle())
                .contextMenu { AddMenuItems() }
            }
            .scrollIndicators(.never)
            }

            UsageFooter()
        }
        .alert("Rename Session", isPresented: presence($renaming)) {
            TextField("Name", text: $text)
            Button("Rename") { if let renaming { workspace.rename(renaming, to: text) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Group", isPresented: presence($renamingGroup)) {
            TextField("Name", text: $text)
            Button("Rename") { if let renamingGroup { workspace.renameGroup(renamingGroup, to: text) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func projectItem(_ project: Project) -> some View {
        let sessions = workspace.sessions(in: project)
        ProjectRow(
            project: project,
            session: sessions.first,
            selected: sessions.first.map { $0.id == workspace.selectedSessionID } ?? false
        ) {
            projectMenu(project)
        }
            .overlay(alignment: .top) { mark(.project(project.id), before: true) }
            .overlay(alignment: .bottom) { mark(.project(project.id), before: false) }
            .onTapGesture { workspace.selectProject(project) }
            .contextMenu { projectMenu(project) }
            .onDrag {
                dragging = .project(project.id)
                return NSItemProvider.merlixItem()
            }
            .onDrop(of: [.merlixItem], delegate: dropDelegate(.project(project.id), height: Self.rowHeight))
        ForEach(sessions.dropFirst()) { session in
            SessionRow(session: session, selected: session.id == workspace.selectedSessionID)
                .padding(.leading, 26)
                .onTapGesture { workspace.select(session.id) }
                .contextMenu { sessionMenu(session) }
                // Dropped elsewhere, it becomes an item of its own.
                .onDrag {
                    dragging = .session(session.id)
                    return NSItemProvider.merlixItem()
                }
        }
    }

    // MARK: Reordering

    private static let rowHeight: CGFloat = 32
    private static let headerHeight: CGFloat = 36

    /// A line where the dragged item would land.
    @ViewBuilder
    private func mark(_ spot: DropSpot, before: Bool) -> some View {
        if let dropMark, dropMark.spot == spot, dropMark.before == before {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 6)
                .offset(y: before ? -1 : 1)
                .allowsHitTesting(false)
        }
    }

    private func dropDelegate(_ spot: DropSpot, height: CGFloat) -> SidebarDropDelegate {
        SidebarDropDelegate(
            spot: spot, height: height, dragging: dragging, mark: $dropMark,
            accepts: { accepts(dragging, at: spot) },
            perform: { before in
                drop(before: before, at: spot)
                dragging = nil
            })
    }

    private func accepts(_ item: DragItem?, at spot: DropSpot) -> Bool {
        switch (item, spot) {
        case (.project, _), (.session, _): true
        // Groups reorder among groups; "Projects" always stays first.
        case (.group, .header(let id)): id != nil
        default: false
        }
    }

    /// Projects dropped on a row land above or below it and join its group;
    /// dropped on a group label they go first in that group. Groups dropped
    /// on another group's label land above or below it.
    private func drop(before: Bool, at spot: DropSpot) {
        switch (dragging, spot) {
        case (.project(let id), .project(let target)):
            guard let targetProject = workspace.projects.first(where: { $0.id == target }) else { return }
            let siblings = workspace.projects.filter { $0.groupID == targetProject.groupID && $0.id != id }
            let anchor: UUID?
            if before {
                anchor = target
            } else {
                let index = siblings.firstIndex { $0.id == target }.map { $0 + 1 }
                anchor = index.flatMap { siblings.indices.contains($0) ? siblings[$0].id : nil }
            }
            workspace.moveProject(id, to: targetProject.groupID, before: anchor)
        case (.project(let id), .header(let group)):
            let first = workspace.projects.first { $0.groupID == group && $0.id != id }
            workspace.moveProject(id, to: group, before: first?.id)
        case (.session(let id), .project(let target)):
            guard let targetProject = workspace.projects.first(where: { $0.id == target }) else { return }
            let siblings = workspace.projects.filter { $0.groupID == targetProject.groupID }
            let index = siblings.firstIndex { $0.id == target }.map { before ? $0 : $0 + 1 }
            let anchor = index.flatMap { siblings.indices.contains($0) ? siblings[$0].id : nil }
            workspace.promote(id, to: targetProject.groupID, before: anchor)
        case (.session(let id), .header(let group)):
            workspace.promote(id, to: group, before: workspace.projects.first { $0.groupID == group }?.id)
        case (.group(let id), .header(let target?)):
            let others = workspace.groups.filter { $0.id != id }
            let anchor: UUID?
            if before {
                anchor = target
            } else {
                let index = others.firstIndex { $0.id == target }.map { $0 + 1 }
                anchor = index.flatMap { others.indices.contains($0) ? others[$0].id : nil }
            }
            workspace.moveGroup(id, before: anchor)
        default:
            break
        }
    }

    private func presence<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    @ViewBuilder
    private func sessionMenu(_ session: Session) -> some View {
        Button("Rename…") {
            text = session.name.isEmpty ? session.displayName : session.name
            renaming = session
        }
        Divider()
        Button("Close Session", role: .destructive) {
            workspace.requestClose(session, processAlive: session.isRunning)
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("Project Settings…") { workspace.editProject(project) }
        Divider()
        Button("New Session") { workspace.addSessionItem(beside: project) }
        Button("New Shell") { workspace.addSessionItem(command: "", beside: project) }
        Menu("Move to Group") {
            Button("None") { workspace.move(project, to: nil) }
                .disabled(project.groupID == nil)
            ForEach(workspace.groups) { group in
                Button(group.name) { workspace.move(project, to: group) }
                    .disabled(project.groupID == group.id)
            }
            Divider()
            Button("New Group…") { workspace.promptForNewGroup(moving: project) }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: project.path)])
        }
        Toggle("Start When Merlix Opens", isOn: Binding(
            get: { project.startsAtLaunch == true },
            set: { workspace.setStartsAtLaunch(project, $0) }))
        if let session = workspace.sessions(in: project).first {
            Button("Rename Session…") {
                text = session.name.isEmpty ? session.displayName : session.name
                renaming = session
            }
        }
        Divider()
        Button("Remove Project", role: .destructive) { workspace.removeProject(project) }
    }

    /// New Session and New Shell for a group: pick one of its projects' folders
    /// (the session lands beside it), or another folder imported into the group.
    @ViewBuilder
    private func newSessionMenus(in group: ProjectGroup?) -> some View {
        let projects = workspace.projects(in: group)
        ForEach([("New Session", "claude"), ("New Shell", "")], id: \.0) { title, command in
            Menu(title) {
                ForEach(projects) { project in
                    Button(project.name) { workspace.addSessionItem(command: command, beside: project) }
                }
                if !projects.isEmpty { Divider() }
                Button("Other Folder…") { workspace.addProjectWithPanel(into: group) }
            }
        }
        Divider()
    }

    @ViewBuilder
    private func groupMenu(_ group: ProjectGroup) -> some View {
        newSessionMenus(in: group)
        Button("Import Project…") { workspace.addProjectWithPanel(into: group) }
        Divider()
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") {
            withAnimation(.smooth(duration: 0.2)) { workspace.toggleCollapsed(group) }
        }
        Button("Rename Group…") {
            text = group.name
            renamingGroup = group
        }
        Button("New Group…") { workspace.promptForNewGroup() }
        Divider()
        Button("Delete Group", role: .destructive) { workspace.deleteGroup(group) }
    }
}

private enum DragItem: Equatable {
    case project(UUID)
    /// A project's second or later session.
    case session(UUID)
    case group(UUID)
}

extension DragItem {
    var isGroup: Bool { if case .group = self { true } else { false } }
}

private enum DropSpot: Equatable {
    case project(UUID)
    /// A group's label; nil is the "Projects" label of ungrouped projects.
    case header(UUID?)
}

extension UTType {
    /// A sidebar row or tab being dragged. Only Merlix's own views accept it,
    /// so dropping one on a terminal pastes nothing.
    static let merlixItem = UTType(exportedAs: "dev.cardozo.merlix.item")
}

extension NSItemProvider {
    /// The views keep what is dragged in their state; the provider only marks the drag as Merlix's.
    static func merlixItem() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.merlixItem.identifier, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        return provider
    }
}

private struct DropMark: Equatable {
    let spot: DropSpot
    let before: Bool
}

private struct SidebarDropDelegate: DropDelegate {
    let spot: DropSpot
    let height: CGFloat
    let dragging: DragItem?
    @Binding var mark: DropMark?
    let accepts: () -> Bool
    let perform: (_ before: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && info.hasItemsConforming(to: [.merlixItem]) && accepts()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        // Onto a label, a project goes into that group: mark below the label.
        let before = if case .header = spot, dragging?.isGroup == false { false } else { info.location.y < height / 2 }
        mark = DropMark(spot: spot, before: before)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if mark?.spot == spot { mark = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let before = mark?.before ?? (info.location.y < height / 2)
        mark = nil
        guard validateDrop(info: info) else { return false }
        perform(before)
        return true
    }
}

/// A group's small label, with how many of its sessions need you. On hover it
/// shows a chevron to collapse the group and a "…" menu.
private struct GroupHeader<Menu: View>: View {
    @Environment(Workspace.self) private var workspace
    let title: String
    let projects: [Project]
    /// Nil for the "Projects" label, which does not collapse.
    let collapsed: Bool?
    let toggle: (() -> Void)?
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        let needsYou = projects.flatMap { workspace.sessions(in: $0) }.filter { $0.status == .needsYou }.count
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            if let collapsed, hovering || collapsed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            Spacer()
            if needsYou > 0 {
                Text("\(needsYou) needs you")
                    .foregroundStyle(.orange)
            }
            MoreButton(visible: hovering, menu: menu)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { toggle?() }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(toggle == nil ? [.isHeader] : [.isHeader, .isButton])
        .accessibilityAction(named: collapsed == true ? "Expand" : "Collapse") { toggle?() }
    }
}

/// "…" that opens a menu; kept in the layout while hidden so rows do not shift.
private struct MoreButton<Content: View>: View {
    let visible: Bool
    @ViewBuilder let menu: () -> Content

    var body: some View {
        Menu(content: menu) {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .help("More")
        .accessibilityLabel("More")
    }
}

/// A project and its first session's status. On hover, "…" replaces the age
/// and opens the project's menu.
private struct ProjectRow<Menu: View>: View {
    let project: Project
    let session: Session?
    let selected: Bool
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            ProjectIconView(project: project, size: 18)
            Text(project.name)
                .fontWeight(session?.unread == true ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // Only working, done and needs-you show; "…" takes the spot on hover.
            ZStack {
                if let session, !hovering {
                    StatusIcon(status: session.status, unread: session.unread)
                        .frame(width: 15, height: 15)
                }
                MoreButton(visible: hovering, menu: menu)
            }
            .frame(width: 22, height: 22)
        }
        .font(.system(size: 13))
        .opacity(session?.isRunning == true || selected || hovering ? 1 : 0.6)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(selected ? 0.1 : hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project.displayPath)
    }
}
