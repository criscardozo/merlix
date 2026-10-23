import SwiftUI

/// The right-hand panel: the selected project's files, and the file open in
/// the editor, which takes the whole panel with a way back to the list.
struct FilesPanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var confirmingBack = false
    @State private var saveError: String?

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
                }
            } else {
                Text(project?.name ?? "Files")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Button {
                    files.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh")
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
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func editor(_ file: EditedFile) -> some View {
        let background = GhosttyRuntime.shared.background
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 0) {
            if file.changedOnDisk {
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
