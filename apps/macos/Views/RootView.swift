import SwiftUI

/// Height of the strip that holds the traffic lights. The sidebar's top bar and
/// the card header both line up with it.
let titleBarHeight: CGFloat = 52
/// Where controls can start to the right of the traffic lights.
let trafficLightsWidth: CGFloat = 80

struct RootView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings
    @AppStorage("sidebarVisible", store: .merlix) private var sidebarVisible = true
    @AppStorage("sidebarWidth", store: .merlix) private var sidebarWidth = 260.0
    @AppStorage(HiddenSidebarStyle.key, store: .merlix) private var hiddenStyle = HiddenSidebarStyle.focus.rawValue

    var body: some View {
        @Bindable var workspace = workspace
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView()
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    // Above the card, so the usage hover card can overhang it.
                    .zIndex(1)
            }
            // Without the sidebar the card fills the window and its header
            // becomes the title bar.
            DetailCard(flush: !sidebarVisible, tabs: !sidebarVisible && hiddenStyle == HiddenSidebarStyle.tabs.rawValue)
                .padding(sidebarVisible ? EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8) : EdgeInsets())
        }
        .overlay(alignment: .topLeading) {
            // Always beside the traffic lights, whether or not the sidebar shows.
            HStack(spacing: 2) {
                SidebarToggle()
                if !sidebarVisible { NewSessionMenu() }
            }
            .padding(.leading, trafficLightsWidth)
            .frame(height: titleBarHeight)
        }
        .overlay(alignment: .topLeading) {
            // Above the card, so the whole gap between sidebar and card grabs.
            if sidebarVisible {
                SidebarResizeHandle(width: $sidebarWidth)
                    .padding(.top, titleBarHeight)
                    .offset(x: sidebarWidth - 5)
            }
        }
        .animation(.smooth(duration: 0.25), value: sidebarVisible)
        .overlay(alignment: .top) { PaletteLayer() }
        .background(SidebarMaterial())
        .ignoresSafeArea()
        // A fixed title: setting it lays the title bar out again, and Claude's
        // spinner would do that several times a second, undoing the traffic
        // light position.
        .navigationTitle("Merlix")
        .background(WindowConfigurator())
        .onChange(of: workspace.settingsRequest) { openSettings() }
        .sheet(item: $workspace.projectDraft) { draft in
            ProjectSheet(draft: draft)
        }
        .sheet(item: $workspace.newGroupPrompt) { prompt in
            NewGroupSheet { name in createGroup(named: name, moving: prompt.projectID) }
        }
    }

    private func createGroup(named name: String, moving projectID: UUID?) {
        let group = workspace.addGroup(named: name)
        if let projectID, let project = workspace.projects.first(where: { $0.id == projectID }) {
            workspace.move(project, to: group)
        }
    }
}

/// Dims the window behind the command palette; a click outside closes it.
private struct PaletteLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.paletteVisible {
            ZStack(alignment: .top) {
                Color.black.opacity(0.15)
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.paletteVisible = false }
                CommandPalette()
                    .padding(.top, 90)
            }
            .transition(.opacity)
        }
    }
}

/// The selected session as a rounded card on the sidebar material: a header with
/// its name, folder and status, then the terminal.
private struct DetailCard: View {
    @Environment(Workspace.self) private var workspace
    let flush: Bool
    /// The header is a strip of tabs, one per session.
    let tabs: Bool

    var body: some View {
        let background = GhosttyRuntime.shared.background
        let fill = Color(red: background.red, green: background.green, blue: background.blue)
            .opacity(background.opacity)
        let shape = RoundedRectangle(cornerRadius: flush ? 0 : 10, style: .continuous)

        VStack(spacing: 0) {
            Group {
                if tabs {
                    SessionTabs()
                } else {
                    CardHeader(session: workspace.selectedSession)
                }
            }
                // Flush, the header is the title bar: leave room for the traffic lights and controls.
                .padding(.leading, flush ? trafficLightsWidth + 56 : 0)
                .frame(height: flush ? titleBarHeight : titleBarHeight - 16)
                .background(fill)
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
            if let session = workspace.selectedSession {
                TerminalHost(session: session)
                    .overlay(alignment: .topTrailing) {
                        if let search = session.search {
                            FindBar(session: session, search: search)
                                .padding(10)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.smooth(duration: 0.18), value: session.search == nil)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(fill)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(flush ? 0 : 0.06)))
        .shadow(color: .black.opacity(flush ? 0 : 0.25), radius: 8, y: 2)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No sessions", systemImage: "terminal")
        } description: {
            Text("Add a project folder to start a Claude Code session in it.")
        } actions: {
            Button("Add Project…") { workspace.addProjectWithPanel() }
                .buttonStyle(.glassProminent)
        }
    }
}

private struct CardHeader: View {
    @Environment(Workspace.self) private var workspace
    let session: Session?

    var body: some View {
        HStack(spacing: 8) {
            if let session, let project = workspace.project(for: session) {
                ProjectIconView(project: project, size: 16)
                Text(project.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                // Further sessions of a project are told apart by their own name.
                if workspace.sessions(in: project).first?.id != session.id {
                    Text(session.displayName)
                        .lineLimit(1)
                }
                Text(project.displayPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 12)
                StatusSummary(session: session)
            } else {
                Spacer()
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

/// "Working", "Done" or "Needs you" on the right of the card header.
private struct StatusSummary: View {
    let session: Session

    var body: some View {
        let label: String? = switch session.status {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .idle: nil
        }
        if let label {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(session.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }
}

/// Shows or hides the sidebar; sits beside the traffic lights.
struct SidebarToggle: View {
    @AppStorage("sidebarVisible", store: .merlix) private var sidebarVisible = true

    var body: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .help(sidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
    }
}

/// "+": choose between a new session, a new group or importing a project.
struct NewSessionMenu: View {
    var body: some View {
        Menu {
            AddMenuItems()
        } label: {
            Image(systemName: "plus")
                .frame(width: 26, height: 24)
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .help("New Session, Group or Project")
    }
}

/// The + menu, also the sidebar's right-click menu.
struct AddMenuItems: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("New Session") { workspace.addSessionItem() }
            .disabled(workspace.projects.isEmpty)
        Button("New Shell") { workspace.addSessionItem(command: "") }
            .disabled(workspace.projects.isEmpty)
        Divider()
        Button("New Group…") { workspace.promptForNewGroup() }
        Button("Import Project…") { workspace.addProjectWithPanel() }
    }
}

/// A thin strip on the sidebar's trailing edge that resizes it.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.columnResize.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(420, max(200, start + value.translation.width))
                    }
                    .onEnded { _ in startWidth = nil })
    }
}

/// Behind-window vibrancy across the whole window: the sidebar and the frame
/// around the card show the desktop through it.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
