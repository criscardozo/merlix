import AppKit
import Observation

/// Projects, their sessions, the selection, and the rules that turn terminal
/// events into session status. Persists to Application Support/Merlix.
@Observable
final class Workspace {
    static let shared = Workspace()

    private(set) var projects: [Project] = []
    private(set) var groups: [ProjectGroup] = []
    /// The project sheet: a new project being imported, or one being edited.
    var projectDraft: ProjectDraft?
    private(set) var sessions: [Session] = []
    private(set) var selectedSessionID: UUID?
    var paletteVisible = false
    /// Asks the window for a new group's name; moves `project` into it when set.
    var newGroupPrompt: NewGroupPrompt?
    /// Bumped to ask the window to open Settings, which only SwiftUI can do.
    var settingsRequest = 0

    private init() {
        GhosttyRuntime.shared.eventHandler = { [weak self] event, view in
            self?.handle(event, from: view)
        }
        ClaudeHooks.shared.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionID }
    }

    func sessions(in project: Project) -> [Session] {
        sessions.filter { $0.projectID == project.id }
    }

    func project(for session: Session) -> Project? {
        projects.first { $0.id == session.projectID }
    }

    func projects(in group: ProjectGroup?) -> [Project] {
        projects.filter { $0.groupID == group?.id }
    }

    /// Sidebar order: projects outside any group first, then each group's.
    var orderedProjects: [Project] {
        projects(in: nil) + groups.flatMap { projects(in: $0) }
    }

    /// Sessions in sidebar order, which is what ⌘1–9 counts through.
    var orderedSessions: [Session] {
        orderedProjects.flatMap { sessions(in: $0) }
    }

    var needsYouCount: Int {
        sessions.filter { $0.status == .needsYou }.count
    }

    // MARK: Projects

    /// Picks a folder, then opens the project sheet to name it and choose its group and icon.
    /// From a group's menu, the project starts in that group.
    func addProjectWithPanel(into group: ProjectGroup? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the project's folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        if let existing = projects.first(where: { $0.path == path }) {
            selectProject(existing)
            return
        }
        projectDraft = ProjectDraft(
            project: Project(id: UUID(), name: ProjectDraft.name(for: url), path: path, groupID: group?.id ?? selectedProjectGroupID),
            isNew: true)
    }

    /// Menus can hold an older copy of the project; always edit the current one.
    func editProject(_ project: Project) {
        guard let current = projects.first(where: { $0.id == project.id }) else { return }
        projectDraft = ProjectDraft(project: current, isNew: false)
    }

    /// Saves the sheet: adds a new project and starts its session, or updates an existing one.
    func commit(_ draft: ProjectDraft) {
        var project = draft.project
        if let image = draft.pickedImage {
            project.iconFile = ProjectIcons.store(image, for: project.id)
        }
        if draft.isNew {
            projects.append(project)
            newSession(in: project.id, command: draft.startsShell ? "" : "claude", resuming: draft.resume)
        } else if let index = projects.firstIndex(where: { $0.id == project.id }) {
            if project.groupID == draft.originalGroupID { project.groupID = projects[index].groupID }
            projects[index] = project
        }
        ProjectIcons.shared.forget(project.id)
        projectDraft = nil
        save()
    }

    /// Every new session gets its own sidebar item: an entry for the same
    /// folder ("notes 2"), so it can be dragged into any group. Beside a
    /// project it lands right after it, in its group; otherwise it starts
    /// outside any group, for the selected project's folder.
    func addSessionItem(command: String = "claude", beside project: Project? = nil) {
        guard let source = project ?? selectedSession.flatMap({ self.project(for: $0) }) ?? orderedProjects.first else {
            addProjectWithPanel()
            return
        }
        let item = copy(of: source, in: project?.groupID)
        if let project, let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects.insert(item, at: index + 1)
        } else {
            projects.append(item)
        }
        newSession(in: item.id, command: command)
    }

    /// Another entry for a project's folder, named "<name> 2", "<name> 3"…
    private func copy(of project: Project, in group: UUID?) -> Project {
        let base = project.name.replacing(/\s\d+$/, with: "")
        var number = 2
        while projects.contains(where: { $0.name == "\(base) \(number)" }) { number += 1 }
        return Project(id: UUID(), name: "\(base) \(number)", path: project.path, groupID: group, iconFile: project.iconFile)
    }

    /// Gives a session that shares a project its own sidebar item, in `group`
    /// before `anchor` (last when nil). Its terminal keeps running.
    func promote(_ sessionID: UUID, to group: UUID?, before anchor: UUID?) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let source = project(for: session) else { return }
        let item = copy(of: source, in: group)
        projects.append(item)
        session.projectID = item.id
        moveProject(item.id, to: group, before: anchor)
    }

    /// Tabs follow sidebar order: within a project they reorder its sessions,
    /// across projects they move the dragged one's project.
    func moveTab(_ id: UUID, nextTo targetID: UUID, before: Bool) {
        guard id != targetID,
              let dragged = sessions.first(where: { $0.id == id }),
              let target = sessions.first(where: { $0.id == targetID }),
              let targetProject = project(for: target) else { return }
        if dragged.projectID == target.projectID {
            sessions.removeAll { $0.id == id }
            let index = sessions.firstIndex { $0.id == targetID } ?? sessions.endIndex
            sessions.insert(dragged, at: before ? index : min(index + 1, sessions.endIndex))
            save()
            return
        }
        let siblings = projects.filter { $0.groupID == targetProject.groupID && $0.id != dragged.projectID }
        let anchor: UUID?
        if before {
            anchor = targetProject.id
        } else {
            let index = siblings.firstIndex { $0.id == targetProject.id }.map { $0 + 1 }
            anchor = index.flatMap { siblings.indices.contains($0) ? siblings[$0].id : nil }
        }
        moveProject(dragged.projectID, to: targetProject.groupID, before: anchor)
    }

    /// Opens the project's first session, starting one if it has none.
    func selectProject(_ project: Project) {
        if let session = sessions(in: project).first {
            select(session.id)
        } else {
            newSession(in: project.id)
        }
    }

    private var selectedProjectGroupID: UUID? {
        selectedSession.flatMap { project(for: $0) }?.groupID
    }

    // MARK: Groups

    func promptForNewGroup(moving project: Project? = nil) {
        newGroupPrompt = NewGroupPrompt(projectID: project?.id)
    }

    @discardableResult
    func addGroup(named name: String) -> ProjectGroup {
        let group = ProjectGroup(id: UUID(), name: name)
        groups.append(group)
        save()
        return group
    }

    func toggleCollapsed(_ group: ProjectGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].collapsed = !groups[index].isCollapsed
        save()
    }

    func renameGroup(_ group: ProjectGroup, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = name
        save()
    }

    /// Its projects stay, outside any group.
    func deleteGroup(_ group: ProjectGroup) {
        for index in projects.indices where projects[index].groupID == group.id {
            projects[index].groupID = nil
        }
        groups.removeAll { $0.id == group.id }
        save()
    }

    /// Puts a project in `group`, before `target`, or last in the group when `target` is nil.
    func moveProject(_ id: UUID, to group: UUID?, before target: UUID?) {
        guard id != target, let from = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects.remove(at: from)
        project.groupID = group
        if let target, let index = projects.firstIndex(where: { $0.id == target }) {
            projects.insert(project, at: index)
        } else if let last = projects.lastIndex(where: { $0.groupID == group }) {
            projects.insert(project, at: last + 1)
        } else {
            projects.append(project)
        }
        save()
    }

    /// Puts a group before `target`, or last when `target` is nil.
    func moveGroup(_ id: UUID, before target: UUID?) {
        guard id != target, let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: from)
        if let target, let index = groups.firstIndex(where: { $0.id == target }) {
            groups.insert(group, at: index)
        } else {
            groups.append(group)
        }
        save()
    }

    func move(_ project: Project, to group: ProjectGroup?) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].groupID = group?.id
        save()
    }

    func removeProject(_ project: Project) {
        for session in sessions(in: project) { close(session) }
        projects.removeAll { $0.id == project.id }
        save()
    }

    // MARK: Sessions

    @discardableResult
    func newSession(
        in projectID: UUID? = nil, command: String = "claude", resuming conversation: ClaudeConversation? = nil
    ) -> Session? {
        let target = projectID
            ?? selectedSession?.projectID
            ?? projects.first?.id
        guard let target else {
            addProjectWithPanel()
            return nil
        }
        let session = Session(
            projectID: target, name: "", command: command,
            claudeSessionID: conversation?.id, transcriptPath: conversation?.transcriptPath)
        sessions.append(session)
        select(session.id)
        save()
        return session
    }

    func select(_ id: UUID?) {
        selectedSessionID = id
        if let session = selectedSession {
            start(session)
            session.unread = false
        }
        for session in sessions {
            for surface in session.allSurfaces { surface.setVisible(session.id == id) }
        }
        save()
    }

    func selectSession(at position: Int) {
        let ordered = orderedSessions
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == selectedSessionID } ?? 0
        let index: Int
        switch position {
        case -1: index = (current - 1 + ordered.count) % ordered.count
        case -2: index = (current + 1) % ordered.count
        case -3: index = ordered.count - 1
        default: index = min(max(position, 1), ordered.count) - 1
        }
        select(ordered[index].id)
    }

    func rename(_ session: Session, to name: String) {
        session.name = name.trimmingCharacters(in: .whitespaces)
        save()
    }

    func close(_ session: Session) {
        for surface in session.allSurfaces { surface.destroy() }
        session.paneHost?.removeFromSuperview()
        session.paneHost = nil
        session.surfaceView = nil
        let ordered = orderedSessions
        let position = ordered.firstIndex { $0.id == session.id }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            let remaining = orderedSessions
            let next = position.flatMap { remaining.indices.contains($0) ? remaining[$0] : remaining.last }
            select(next?.id)
        }
        updateBadge()
        save()
    }

    func requestClose(_ session: Session, processAlive: Bool) {
        if processAlive {
            let alert = NSAlert()
            alert.messageText = "Close “\(session.displayName)”?"
            alert.informativeText = "A process is still running in this session and will be terminated."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        close(session)
    }

    func closeSelectedSession() {
        if let session = selectedSession {
            guard let surface = session.activeSurface else { return close(session) }
            requestClose(surface, in: session, processAlive: surface.needsConfirmClose)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// Creates the terminal the first time a session is shown. Restored sessions
    /// stay dormant until then so launching Merlix does not start every Claude.
    func start(_ session: Session) {
        guard session.surfaceView == nil, let project = project(for: session) else { return }
        // Pick Claude's conversation id now rather than learning it from the
        // first hook: a session closed before its first prompt still resumes.
        if session.isClaude, session.claudeSessionID == nil {
            let id = UUID().uuidString.lowercased()
            session.claudeSessionID = id
            session.transcriptPath = ClaudeTranscripts.transcript(for: id, in: project.path).path
            save()
        }
        // The PTY echoes initial input before the prompt draws; clearing first
        // leaves Claude Code alone on screen instead of the command twice.
        let surface = TerminalSurfaceView(
            sessionID: session.id,
            workingDirectory: project.path,
            initialInput: session.startCommand.isEmpty ? nil : "clear && \(session.startCommand)\n",
            environment: ClaudeHooks.shared.environment(for: session.id))
        session.surfaceView = surface
        session.paneHost = PaneHost(surface)
        session.isRunning = true
        session.lastActivity = .now
    }

    // MARK: Splits

    func splitSelected(_ direction: SplitDirection) {
        guard let session = selectedSession, let surface = session.activeSurface else { return }
        split(surface, in: session, direction: direction)
    }

    /// A shell beside `surface`, in the folder that terminal is in.
    func split(_ surface: TerminalSurfaceView, in session: Session, direction: SplitDirection) {
        guard let host = session.paneHost, let project = project(for: session) else { return }
        let directory = surface === session.surfaceView ? session.pwd : nil
        let pane = TerminalSurfaceView(
            sessionID: session.id,
            workingDirectory: directory ?? project.path,
            initialInput: nil,
            environment: ClaudeHooks.shared.environment(for: session.id))
        host.split(surface, adding: pane, direction: direction)
        pane.window?.makeFirstResponder(pane)
    }

    /// The first pane runs the session's command, so closing it closes the
    /// session; any other pane just goes away.
    func requestClose(_ surface: TerminalSurfaceView, in session: Session, processAlive: Bool) {
        guard surface !== session.surfaceView, let host = session.paneHost else {
            requestClose(session, processAlive: processAlive)
            return
        }
        if processAlive {
            let alert = NSAlert()
            alert.messageText = "Close this pane?"
            alert.informativeText = "A process is still running in it and will be terminated."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let next = host.neighbour(of: surface, toward: .previous)
        host.remove(surface)
        surface.destroy()
        let focus = next ?? session.surfaceView
        session.focusedSurface = focus
        if let focus { focus.window?.makeFirstResponder(focus) }
    }

    // MARK: Terminal events

    private func handle(_ event: TerminalEvent, from view: TerminalSurfaceView?) {
        let session = view.flatMap { view in sessions.first { $0.id == view.sessionID } }

        switch event {
        case .newSession:
            addSessionItem(beside: session.flatMap { project(for: $0) })
        case .gotoSession(let position):
            selectSession(at: Int(position))
        case .closeRequested(let processAlive):
            // Never free a surface from inside its own callback.
            guard let session, let view else { return }
            DispatchQueue.main.async { [weak self] in
                self?.requestClose(view, in: session, processAlive: processAlive)
            }
        case .title(let title):
            session?.title = title
            // Without hooks, the title is the only sign of a Claude typed by hand.
            if let session, view === session.surfaceView, !session.isClaude, !session.hooksActive {
                followHandStartedClaude(in: session, title: title)
            }
        case .pwd(let pwd):
            if let session, view === session.surfaceView { session.pwd = pwd }
        case .progress(let progress):
            guard let session else { return }
            apply(progress, to: session)
        case .notification(let title, let body):
            // Hooks already report permission prompts and questions, with more detail.
            guard let session, !session.hooksActive else { return }
            set(session, to: .needsYou)
            if !isVisible(session) {
                Notifier.shared.post(title: title.isEmpty ? session.displayName : title, body: body, sessionID: session.id)
            }
        case .bell:
            guard let session, !isVisible(session) else { return }
            session.unread = true
        case .userInput:
            guard let session, session.status == .needsYou else { return }
            set(session, to: .idle)
        case .focused:
            session?.unread = false
            session?.focusedSurface = view
        case .openLink(let text):
            openLink(text, from: session)
        case .commandPalette:
            paletteVisible.toggle()
        case .openSettings:
            settingsRequest += 1
        case .searchStarted(let needle):
            guard let session else { return }
            if let search = session.search {
                if let needle, !needle.isEmpty { search.needle = needle }
                search.focusRequest += 1
            } else {
                session.search = SearchState(needle: needle ?? "")
            }
        case .searchEnded:
            session?.search = nil
            if let view { view.window?.makeFirstResponder(view) }
        case .searchTotal(let total):
            session?.search?.total = total
        case .searchSelected(let selected):
            session?.search?.selected = selected
        case .newSplit(let direction):
            guard let session, let view else { return }
            split(view, in: session, direction: direction)
        case .gotoSplit(let target):
            guard let view, let next = session?.paneHost?.neighbour(of: view, toward: target) else { return }
            next.window?.makeFirstResponder(next)
        case .resizeSplit(let direction, let amount):
            guard let view else { return }
            session?.paneHost?.resize(view, toward: direction, by: CGFloat(amount))
        case .equalizeSplits:
            session?.paneHost?.equalize()
        }
    }

    private func apply(_ progress: TerminalProgress, to session: Session) {
        switch progress {
        case .working:
            if !session.hooksActive { set(session, to: .working) }
        case .paused:
            if !session.hooksActive { set(session, to: .needsYou) }
        case .failed, .finished:
            // Still used with hooks: an Esc interrupt fires no Stop hook, but it
            // does clear the progress report.
            guard session.status == .working else { return }
            set(session, to: .done)
        }
    }

    // MARK: Links

    /// ⌘-click on a link in a terminal. URLs go to the browser; a file path,
    /// relative to where Claude runs in that session (or the project), opens in
    /// an editor tab at its `:line` if it has one.
    func openLink(_ text: String, from session: Session?) {
        // "main.swift:25" parses as a URL with the scheme "main.swift", so only
        // "scheme://…" and the few schemes without slashes count as URLs.
        let schemes = ["mailto:", "tel:", "magnet:", "news:"]
        if !text.hasPrefix("file:"), text.contains("://") || schemes.contains(where: text.hasPrefix),
           let url = URL(string: text) {
            NSWorkspace.shared.open(url)
            return
        }
        var path = text.hasPrefix("file://") ? (URL(string: text)?.path(percentEncoded: false) ?? text) : text
        var line: Int?
        if let match = path.firstMatch(of: /:(\d+)(?::\d+)?$/) {
            line = Int(match.1)
            path = String(path[..<match.range.lowerBound])
        }
        path = (path as NSString).expandingTildeInPath
        let project = session.flatMap { self.project(for: $0) }?.path
        let bases = [session?.claudeDirectory, session?.pwd, project].compactMap { $0 }
        let candidates = path.hasPrefix("/") ? [path] : bases.map { ($0 as NSString).appendingPathComponent(path) }
        var isDirectory: ObjCBool = false
        guard let found = candidates.map({ ($0 as NSString).standardizingPath })
            .first(where: { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) })
        else {
            NSSound.beep()
            return
        }
        if isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: found)])
        } else if !ProjectFiles.shared.openInTab(path: found, line: line) {
            // Images and other binaries: their own app.
            NSWorkspace.shared.open(URL(filePath: found))
        }
    }

    // MARK: Claude started by hand

    /// In a shell session, a Claude typed by hand has no hooks. Its title gives
    /// it away, and the newest transcript in the shell's folder is its
    /// conversation, which a restart then resumes. Leaving Claude forgets it.
    private func followHandStartedClaude(in session: Session, title: String) {
        guard Session.isClaudeTitle(title) else {
            // Before Claude starts the shell has its own title too; only a shell
            // title after Claude's means it exited.
            if session.handClaudeRunning {
                session.handClaudeRunning = false
                session.claudeDirectory = nil
                session.claudeSessionID = nil
                session.transcriptPath = nil
                save()
            }
            return
        }
        session.handClaudeRunning = true
        // The title changes several times a second while Claude works.
        if let last = session.lastTranscriptScan, Date.now.timeIntervalSince(last) < 15 { return }
        session.lastTranscriptScan = .now
        guard let folder = session.pwd ?? project(for: session)?.path else { return }
        Task {
            let found = await Task.detached { ClaudeTranscripts.conversations(in: folder, limit: 1).first }.value
            guard let found, Date.now.timeIntervalSince(found.modified) < 300,
                  found.id != session.claudeSessionID || session.claudeDirectory != folder else { return }
            session.claudeSessionID = found.id
            session.transcriptPath = found.transcriptPath
            session.claudeDirectory = folder
            save()
        }
    }

    // MARK: Claude Code hooks

    private func handle(_ event: HookEvent) {
        guard let session = sessions.first(where: { $0.id == event.sessionID }) else { return }
        session.hooksActive = true
        // A Claude typed by hand in a shell session ended (not /clear, which
        // starts another conversation right away): the shell is back.
        if event.name == "SessionEnd" {
            if !session.isClaude, event.reason != "clear" {
                session.claudeSessionID = nil
                session.transcriptPath = nil
                session.claudeDirectory = nil
                save()
            }
            set(session, to: .idle)
            return
        }
        // /clear starts a new Claude session in the same terminal; follow it.
        let directory = session.isClaude ? session.claudeDirectory : (event.cwd ?? session.claudeDirectory)
        if let id = event.claudeSessionID,
           id != session.claudeSessionID || event.transcriptPath != session.transcriptPath || directory != session.claudeDirectory {
            session.claudeSessionID = id
            session.transcriptPath = event.transcriptPath
            session.claudeDirectory = directory
            save()
        }
        if event.name == "SessionStart" { return }

        switch event.name {
        case "PreToolUse" where event.toolName == "AskUserQuestion":
            // Claude stops to ask; no permission request comes with it.
            needsYou(session, subtitle: "Asks a question", body: event.detail ?? "Has a question for you")
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
            set(session, to: .working)
        case "PermissionRequest":
            needsYou(session, subtitle: Self.permissionSubtitle(event.toolName), body: event.detail ?? event.message ?? "")
        case "Notification":
            switch event.notificationType {
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                needsYou(session, subtitle: "Needs your input", body: event.message ?? "Has a question for you")
            default:
                // permission_prompt duplicates PermissionRequest; idle_prompt
                // arrives a minute after Stop already marked it done.
                break
            }
        case "Stop", "StopFailure":
            set(session, to: .done)
        default:
            break
        }
    }

    private func needsYou(_ session: Session, subtitle: String, body: String) {
        let wasWaiting = session.status == .needsYou
        set(session, to: .needsYou)
        if !wasWaiting, !isVisible(session) {
            let title = project(for: session)?.name ?? session.displayName
            Notifier.shared.post(title: title, subtitle: subtitle, body: body, sessionID: session.id)
        }
    }

    private static func permissionSubtitle(_ tool: String?) -> String {
        switch tool {
        case "Bash": "Wants to run a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Wants to edit a file"
        case "WebFetch": "Wants to open a page"
        case "WebSearch": "Wants to search the web"
        case "ExitPlanMode": "Has a plan for you"
        case let tool?: "Wants to use \(tool)"
        case nil: "Needs your permission"
        }
    }

    private func set(_ session: Session, to status: SessionStatus) {
        guard session.status != status else { return }
        session.status = status
        session.lastActivity = .now
        if status == .done || status == .needsYou {
            session.unread = !isVisible(session)
        }
        updateBadge()
    }

    private func isVisible(_ session: Session) -> Bool {
        NSApp.isActive && session.id == selectedSessionID && (NSApp.keyWindow?.isVisible ?? false)
    }

    private func updateBadge() {
        let count = needsYouCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        struct SessionRecord: Codable {
            let id: UUID
            let projectID: UUID
            let name: String
            let command: String
            var lastActivity: Date?
            var claudeSessionID: String?
            var transcriptPath: String?
            var claudeDirectory: String?
        }

        var projects: [Project]
        var groups: [ProjectGroup]?
        var sessions: [SessionRecord]
        var selectedSessionID: UUID?
    }

    /// `MERLIX_WORKSPACE` points a test instance at its own file, so it never
    /// touches the workspace of the copy in daily use. Its preferences live in
    /// `UserDefaults.merlix`, a separate suite, for the same reason.
    private static var storeURL: URL {
        if let path = ProcessInfo.processInfo.environment["MERLIX_WORKSPACE"] {
            return URL(filePath: path)
        }
        return URL.applicationSupportDirectory
            .appending(path: "Merlix", directoryHint: .isDirectory)
            .appending(path: "workspace.json")
    }

    func restore() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        projects = snapshot.projects
        groups = snapshot.groups ?? []
        sessions = snapshot.sessions.compactMap { record in
            guard projects.contains(where: { $0.id == record.projectID }) else { return nil }
            return Session(
                id: record.id, projectID: record.projectID, name: record.name, command: record.command,
                lastActivity: record.lastActivity ?? .now,
                claudeSessionID: record.claudeSessionID, transcriptPath: record.transcriptPath,
                claudeDirectory: record.claudeDirectory)
        }
        select(snapshot.selectedSessionID ?? orderedSessions.first?.id)
    }

    func save() {
        let snapshot = Snapshot(
            projects: projects,
            groups: groups,
            sessions: orderedSessions.map {
                .init(
                    id: $0.id, projectID: $0.projectID, name: $0.name, command: $0.command,
                    lastActivity: $0.lastActivity, claudeSessionID: $0.claudeSessionID, transcriptPath: $0.transcriptPath,
                    claudeDirectory: $0.claudeDirectory)
            },
            selectedSessionID: selectedSessionID)
        do {
            let url = Self.storeURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            logger.error("saving workspace failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct NewGroupPrompt: Identifiable {
    let id = UUID()
    let projectID: UUID?
}

extension UserDefaults {
    /// Merlix's preferences; a test instance (`MERLIX_WORKSPACE`) gets its own suite.
    nonisolated(unsafe) static let merlix: UserDefaults =
        ProcessInfo.processInfo.environment["MERLIX_WORKSPACE"] == nil
            ? .standard
            : UserDefaults(suiteName: "dev.cardozo.merlix.test") ?? .standard
}
