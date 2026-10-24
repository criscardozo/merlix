import SwiftUI

/// The right-hand panel: the selected project's files, and the file open in
/// the editor, which takes the whole panel with a way back to the list.
struct FilesPanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var confirmingBack = false
    @State private var saveError: String?
    /// The folder a new file goes into, while its name is being asked.
    @State private var newFileFolder: String?

    var body: some View {
        let files = ProjectFiles.shared
        let project = workspace.selectedSession.flatMap { workspace.project(for: $0) }
        VStack(spacing: 0) {
            header(files, project: project)
                .frame(height: titleBarHeight)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            if let file = files.openFile {
                editor(file)
            } else {
                tree(files)
            }
        }
        .task(id: project?.path) { files.show(project?.path) }
        .alert("Save changes to “\(files.openFile?.url.lastPathComponent ?? "")”?", isPresented: $confirmingBack) {
            Button("Save") { if save(files.openFile) { files.openFile = nil } }
            Button("Don't Save", role: .destructive) { files.openFile = nil }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: Binding(get: { newFileFolder != nil }, set: { if !$0 { newFileFolder = nil } })) {
            NameSheet(title: "New File", placeholder: "name.swift, or src/name.ts") { name in
                guard let folder = newFileFolder else { return }
                do {
                    let path = try files.createFile(named: name, in: folder)
                    files.open(path)
                } catch {
                    saveError = error.localizedDescription
                }
            }
        }
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private func header(_ files: ProjectFiles, project: Project?) -> some View {
        HStack(spacing: 6) {
            if let file = files.openFile {
                Button {
                    if file.isDirty { confirmingBack = true } else { files.openFile = nil }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to Files")
                .accessibilityLabel("Back to Files")
                Text(file.url.lastPathComponent)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path(percentEncoded: false))
                if file.isDirty {
                    Circle().fill(.secondary).frame(width: 7, height: 7).help("Unsaved changes")
                }
                Spacer()
                if file.isDirty {
                    Button("Save") { _ = save(file) }
                        .controlSize(.small)
                        .help("Save (⌘S)")
                        .accessibilityLabel("Save")
                }
                iconButton("arrow.up.left.and.arrow.down.right", help: "Open in Tab") { files.openInTab(file) }
            } else {
                Text(project?.name ?? "Files")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if let root = files.root {
                    iconButton("doc.badge.plus", help: "New File") { newFileFolder = root }
                }
                iconButton("arrow.clockwise", help: "Refresh") { files.refresh() }
            }
        }
        .font(.system(size: 13))
    }

    @ViewBuilder
    private func tree(_ files: ProjectFiles) -> some View {
        if let error = files.openError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if files.loading {
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        } else if files.root == nil {
            Text("Select a session to see its project's files.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(files.nodes, children: \.children) { node in
                FileRow(node: node)
                    .contentShape(Rectangle())
                    .onTapGesture { if !node.isDirectory { files.open(node.path) } }
                    .contextMenu { rowMenu(node, files: files) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu {
                if let root = files.root {
                    Button("New File…") { newFileFolder = root }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ node: FileNode, files: ProjectFiles) -> some View {
        if !node.isDirectory {
            Button("Open") { files.open(node.path) }
            Button("Open in Tab") { files.openInTab(path: node.path) }
            Divider()
        }
        Button("New File…") {
            newFileFolder = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: node.path)])
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func editor(_ file: EditedFile) -> some View {
        let background = GhosttyRuntime.shared.background
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 0) {
            if file.changedOnDisk { ChangedOnDiskBar(file: file) }
            CodeEditor(file: file, background: background)
        }
        .background(Color(red: background.red, green: background.green, blue: background.blue).opacity(background.opacity))
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.06)))
        .padding([.horizontal, .bottom], 8)
    }

    /// Saves and reports failures; returns whether it saved.
    private func save(_ file: EditedFile?) -> Bool {
        guard let file else { return false }
        do {
            try file.save()
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

extension EditedFile {
    /// Saves, or tells why it could not; returns whether it saved.
    @discardableResult
    func saveOrAlert() -> Bool {
        do {
            try save()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't save “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }
}

private struct FileRow: View {
    let node: FileNode

    var body: some View {
        Label {
            Text(node.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: Self.symbol(for: node))
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
        }
        .font(.system(size: 12.5))
        .help(node.path)
    }

    private static func symbol(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "json", "jsonc": return "curlybraces"
        case "md", "markdown", "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "icns", "ico": return "photo"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "sh", "zsh":
            return "chevron.left.forwardslash.chevron.right"
        case "yml", "yaml", "toml", "plist", "ini", "env", "conf": return "gearshape"
        case "lock": return "lock"
        default: return "doc"
        }
    }
}

/// Shown over an editor whose file changed on disk while it had unsaved edits.
struct ChangedOnDiskBar: View {
    let file: EditedFile

    var body: some View {
        HStack(spacing: 8) {
            Text("Changed on disk")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Reload") { file.reload() }
            Button("Keep Mine") { file.changedOnDisk = false }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.18))
    }
}

/// Above the card's content when a project has files open in tabs: the
/// terminal first, then each file, closable.
struct FileTabStrip: View {
    let root: String
    @State private var closing: EditedFile?

    var body: some View {
        let files = ProjectFiles.shared
        let active = files.activeFile(in: root)
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                chip(title: "Terminal", symbol: "terminal", selected: active == nil, dirty: false, close: nil) {
                    files.activeTab[root] = nil
                }
                ForEach(files.tabs[root] ?? [], id: \.url) { file in
                    chip(title: file.url.lastPathComponent, symbol: "doc.text", selected: active === file,
                         dirty: file.isDirty, close: { if file.isDirty { closing = file } else { files.closeTab(file, in: root) } }) {
                        files.activeTab[root] = file.url
                    }
                    .help(file.url.path(percentEncoded: false))
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
        .alert("Save changes to “\(closing?.url.lastPathComponent ?? "")”?",
               isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button("Save") {
                if let closing, closing.saveOrAlert() { files.closeTab(closing, in: root) }
            }
            Button("Don't Save", role: .destructive) { if let closing { files.closeTab(closing, in: root) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chip(
        title: String, symbol: String, selected: Bool, dirty: Bool, close: (() -> Void)?, select: @escaping () -> Void
    ) -> some View {
        TabChip(title: title, symbol: symbol, selected: selected, dirty: dirty, close: close)
            .onTapGesture(perform: select)
    }
}

private struct TabChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    let dirty: Bool
    let close: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
            if let close {
                ZStack {
                    if dirty && !hovering {
                        Circle().fill(.secondary).frame(width: 6, height: 6)
                    } else {
                        Button(action: close) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(hovering || selected ? 1 : 0)
                        .help("Close Tab")
                        .accessibilityLabel("Close Tab")
                    }
                }
                .frame(width: 14, height: 14)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(selected ? 0.12 : hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
