import SwiftUI

/// A project's icon, or its initial on a colour picked from its name.
struct ProjectIconView: View {
    let project: Project
    let size: CGFloat

    var body: some View {
        if let image = ProjectIcons.shared.image(for: project) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            MonogramIcon(name: project.name, size: size)
        }
    }
}

struct MonogramIcon: View {
    let name: String
    let size: CGFloat

    private static let colours: [Color] = [.orange, .pink, .purple, .indigo, .blue, .teal, .green, .brown]

    var body: some View {
        let index = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % Self.colours.count
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Self.colours[index].gradient)
            .overlay {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

/// Add a folder as a project, or edit one: name, folder, group and icon.
struct ProjectSheet: View {
    @Environment(Workspace.self) private var workspace
    @State var draft: ProjectDraft
    @State private var preview: NSImage?
    @State private var creatingGroup = false
    @State private var conversations: [ClaudeConversation] = []
    @State private var resuming = false

    private static let newGroupTag = UUID()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Group {
                            if let preview {
                                Image(nsImage: preview)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                MonogramIcon(name: draft.project.name, size: 56)
                            }
                        }
                        TextField("Name", text: $draft.project.name, prompt: Text("Project name"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(draft.project.displayPath)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    Picker("Group", selection: groupSelection) {
                        Text("None").tag(UUID?.none)
                        ForEach(workspace.groups) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                        Divider()
                        Text("New Group…").tag(Optional(Self.newGroupTag))
                    }
                    LabeledContent("Icon") {
                        HStack {
                            Text(iconSource)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if draft.project.usesInitials != true {
                                Button("Use Initials") {
                                    draft.pickedImage = nil
                                    draft.project.iconFile = nil
                                    draft.project.usesInitials = true
                                }
                                .help("Show the project's initial instead of an image")
                            }
                            if draft.pickedImage != nil || draft.project.iconFile != nil || draft.project.usesInitials == true {
                                Button("Automatic") {
                                    draft.pickedImage = nil
                                    draft.project.iconFile = nil
                                    draft.project.usesInitials = nil
                                }
                                .help("Find an icon in the folder or on GitHub")
                            }
                            Button("Choose…", action: chooseImage)
                        }
                    }
                }
                if draft.isNew {
                    Section("Claude") {
                        Picker("Start with", selection: $resuming) {
                            Text("A new session").tag(false)
                            Text("A previous session").tag(true)
                                .disabled(conversations.isEmpty)
                        }
                        .pickerStyle(.radioGroup)
                        if resuming {
                            Picker("Session", selection: $draft.resume) {
                                ForEach(conversations) { conversation in
                                    Text("\(conversation.title) · \(conversation.modified.formatted(.relative(presentation: .named)))")
                                        .tag(Optional(conversation))
                                }
                            }
                        } else if conversations.isEmpty {
                            Text("No earlier Claude sessions in this folder.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.projectDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Project" : "Save") { workspace.commit(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.project.name.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: "\(draft.project.path)|\(draft.pickedImage?.path ?? draft.project.iconFile ?? "")|\(draft.project.usesInitials == true)") {
            preview = draft.project.usesInitials == true ? nil : await ProjectIcons.resolve(
                path: draft.project.path, iconFile: draft.pickedImage?.path ?? draft.project.iconFile)
        }
        .task(id: draft.project.path) {
            guard draft.isNew else { return }
            let folder = draft.project.path
            conversations = await Task.detached { ClaudeTranscripts.conversations(in: folder) }.value
            if conversations.isEmpty { resuming = false }
        }
        .onChange(of: resuming) {
            draft.resume = resuming ? (draft.resume ?? conversations.first) : nil
        }
        .sheet(isPresented: $creatingGroup) {
            NewGroupSheet { name in draft.project.groupID = workspace.addGroup(named: name).id }
        }
    }

    private var trimmed: ProjectDraft {
        var copy = draft
        copy.project.name = copy.project.name.trimmingCharacters(in: .whitespaces)
        return copy
    }

    private var groupSelection: Binding<UUID?> {
        Binding(
            get: { draft.project.groupID },
            set: { value in
                if value == Self.newGroupTag {
                    creatingGroup = true
                } else {
                    draft.project.groupID = value
                }
            })
    }

    /// Where the icon comes from, in words.
    private var iconSource: String {
        if draft.project.usesInitials == true { return "Initials" }
        if let picked = draft.pickedImage { return picked.lastPathComponent }
        if draft.project.iconFile != nil { return "Custom image" }
        if let url = ProjectIcons.localIcon(in: draft.project.path) {
            let root = URL(filePath: draft.project.path, directoryHint: .isDirectory).standardizedFileURL.path
            return String(url.standardizedFileURL.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let owner = ProjectIcons.githubOwner(in: draft.project.path) { return "GitHub · \(owner)" }
        return "Initial"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(filePath: draft.project.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let oldFolderName = URL(filePath: draft.project.path).lastPathComponent
        if draft.project.name == oldFolderName { draft.project.name = url.lastPathComponent }
        draft.project.path = url.standardizedFileURL.path(percentEncoded: false)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(filePath: draft.project.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.pickedImage = url
        draft.project.usesInitials = nil
    }
}
