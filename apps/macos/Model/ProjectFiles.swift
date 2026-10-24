import CoreServices
import Foundation
import Observation

/// A file or folder in the files panel. Folders have children; files do not.
struct FileNode: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    var children: [FileNode]?

    var id: String { path }
    var isDirectory: Bool { children != nil }
}

/// A file open in the editor: the text being edited and what is on disk.
@Observable
final class EditedFile {
    let url: URL
    var text: String
    private(set) var savedText: String
    /// Bumped when the text is replaced from disk, so the editor reloads it.
    private(set) var revision = 0
    /// The file changed on disk while it had unsaved edits.
    var changedOnDisk = false
    /// A line the editor should scroll to and select, once.
    var revealLine: Int?
    /// Its own undo history, which survives switching tabs; the window's
    /// would be shared by every editor and the terminal.
    @ObservationIgnored let undoManager = UndoManager()

    var isDirty: Bool { text != savedText }

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        savedText = text
    }

    func save() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        savedText = text
        changedOnDisk = false
    }

    /// Takes the disk's version; unsaved edits are lost.
    func reload() {
        guard let disk = try? String(contentsOf: url, encoding: .utf8) else { return }
        savedText = disk
        changedOnDisk = false
        replaceText(disk)
    }

    /// Replaces the text from outside the editor, which then shows it.
    func replaceText(_ new: String) {
        text = new
        revision += 1
        undoManager.removeAllActions()
    }

    /// Called when the file changed on disk: reload it, unless that would
    /// throw away edits, in which case ask.
    func diskChanged() {
        guard let disk = try? String(contentsOf: url, encoding: .utf8), disk != savedText else { return }
        if isDirty {
            changedOnDisk = true
        } else {
            reload()
        }
    }
}

/// The files of the selected session's project, kept current while Claude
/// creates, edits and deletes them, and the file open in the editor.
@Observable
final class ProjectFiles {
    static let shared = ProjectFiles()

    private(set) var root: String?
    private(set) var nodes: [FileNode] = []
    private(set) var loading = false
    var openFile: EditedFile?
    /// Files opened in tabs over the terminal, per project folder.
    private(set) var tabs: [String: [EditedFile]] = [:]
    /// The tab each project's card shows; no entry means the terminal.
    var activeTab: [String: URL] = [:]
    /// Why the last file could not be opened (binary, too large).
    var openError: String?

    /// Files larger than this open read-only and without colours.
    static let largeFile = 2_000_000

    /// Each project keeps the file it had open, unsaved edits included.
    @ObservationIgnored private var buffers: [String: EditedFile] = [:]
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Shows `path`'s files; nothing changes if it is already shown.
    func show(_ path: String?) {
        guard path != root else { return }
        stopWatching()
        if let root { buffers[root] = openFile }
        root = path
        nodes = []
        // Taken out, so a file closed later is not still counted as unsaved.
        openFile = path.flatMap { buffers.removeValue(forKey: $0) }
        openError = nil
        // Changes made while this project was not being watched.
        if let path {
            for file in tabs[path] ?? [] { file.diskChanged() }
            openFile?.diskChanged()
        }
        guard let path else { return }
        refresh()
        watch(path)
    }

    func refresh() {
        guard let root else { return }
        loading = nodes.isEmpty
        refreshTask?.cancel()
        refreshTask = Task {
            // Changes come in bursts (a build, a checkout); list once they settle.
            if !loading {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            let tree = await Task.detached { Self.tree(at: root) }.value
            guard !Task.isCancelled, self.root == root else { return }
            nodes = tree
            loading = false
        }
    }

    /// Shows `path` in the panel, or brings its tab forward if it has one, so
    /// a file is never open twice with edits drifting apart.
    func open(_ path: String) {
        openError = nil
        if let root, let tab = tabs[root]?.first(where: { Self.same($0.url, path) }) {
            activeTab[root] = tab.url
            return
        }
        if let openFile, Self.same(openFile.url, path) { return }
        if let file = load(path) { openFile = file }
    }

    /// Reads a text file; on failure says why in `openError`.
    private func load(_ path: String) -> EditedFile? {
        let url = URL(filePath: path)
        guard let data = try? Data(contentsOf: url) else {
            openError = "Merlix could not read this file."
            return nil
        }
        guard data.count <= Self.largeFile * 5 else {
            openError = "This file is too large to open here."
            return nil
        }
        guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else {
            openError = "This looks like a binary file."
            return nil
        }
        return EditedFile(url: url, text: text)
    }

    nonisolated private static func same(_ url: URL, _ path: String) -> Bool {
        url.path(percentEncoded: false) == path
    }

    /// Open files with edits not yet saved, in any project.
    var unsavedFiles: [EditedFile] {
        (Array(buffers.values) + [openFile].compactMap { $0 } + tabs.values.flatMap { $0 }).filter(\.isDirty)
            .reduce(into: [EditedFile]()) { list, file in if !list.contains(where: { $0 === file }) { list.append(file) } }
    }

    // MARK: Tabs

    func activeFile(in root: String) -> EditedFile? {
        guard let url = activeTab[root] else { return nil }
        return tabs[root]?.first { $0.url == url }
    }

    /// The file ⌘S saves: the tab on show, else the one in the panel.
    var currentFile: EditedFile? {
        root.flatMap { activeFile(in: $0) } ?? openFile
    }

    /// Moves `file` from the panel into a tab of the current project (or
    /// focuses its tab if it already has one), keeping any unsaved edits.
    func openInTab(_ file: EditedFile) {
        guard let root else { return }
        if openFile === file { openFile = nil }
        var list = tabs[root] ?? []
        if let existing = list.first(where: { $0.url == file.url }) {
            if existing !== file, file.isDirty { existing.replaceText(file.text) }
        } else {
            list.append(file)
        }
        tabs[root] = list
        activeTab[root] = file.url
    }

    /// Returns false when the file cannot be shown as text.
    @discardableResult
    func openInTab(path: String, line: Int? = nil) -> Bool {
        openError = nil
        // The panel's copy moves over with its edits; anything else is read
        // without touching the panel.
        let file = root.flatMap { tabs[$0] }?.first(where: { Self.same($0.url, path) })
            ?? openFile.flatMap { Self.same($0.url, path) ? $0 : nil }
            ?? load(path)
        guard let file else { return false }
        file.revealLine = line
        openInTab(file)
        return true
    }

    func closeTab(_ file: EditedFile, in root: String) {
        tabs[root]?.removeAll { $0 === file }
        if activeTab[root] == file.url { activeTab[root] = nil }
    }

    /// Creates an empty file at `name` (which may include folders) inside
    /// `folder`, and returns its path.
    func createFile(named name: String, in folder: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.split(separator: "/").contains("..") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = URL(filePath: folder, directoryHint: .isDirectory).appending(path: trimmed)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
        refresh()
        return url.path(percentEncoded: false)
    }

    // MARK: Listing

    /// Folders the listing skips when the project is not a git repository.
    nonisolated private static let skipped: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", ".next", ".turbo", "vendor",
    ]

    /// The project's files: git's own list when it is a repository, so
    /// ignored files stay out; otherwise a walk that skips build folders.
    nonisolated static func tree(at root: String) -> [FileNode] {
        let paths = gitFiles(at: root) ?? walkedFiles(at: root)
        return build(paths.prefix(20_000), root: root)
    }

    nonisolated private static func gitFiles(at root: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    nonisolated private static func walkedFiles(at root: String) -> [String] {
        let base = URL(filePath: root, directoryHint: .isDirectory)
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
        else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) || walker.level > 8 {
                walker.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory {
                paths.append(String(url.path(percentEncoded: false).dropFirst(base.path(percentEncoded: false).count)))
            }
            if paths.count >= 20_000 { break }
        }
        return paths
    }

    /// Turns relative paths into a tree: folders first, then files, by name.
    nonisolated private final class Folder {
        var folders: [String: Folder] = [:]
        var files: [String] = []
    }

    nonisolated private static func build(_ paths: ArraySlice<String>, root: String) -> [FileNode] {
        let top = Folder()
        for path in paths {
            var folder = top
            let parts = path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            if let file = parts.last { folder.files.append(file) }
        }
        let base = root.hasSuffix("/") ? root : root + "/"
        func nodes(_ folder: Folder, prefix: String) -> [FileNode] {
            let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
            let folders = folder.folders.keys.sorted(by: order).map { name in
                FileNode(path: base + prefix + name, name: name, children: nodes(folder.folders[name]!, prefix: prefix + name + "/"))
            }
            let files = folder.files.sorted(by: order).map { FileNode(path: base + prefix + $0, name: $0, children: nil) }
            return folders + files
        }
        return nodes(top, prefix: "")
    }

    // MARK: Watching

    /// FSEvents on the project: the tree refreshes and the open file reloads
    /// when something on disk changes, whoever changed it.
    private func watch(_ path: String) {
        var context = FSEventStreamContext()
        guard let stream = FSEventStreamCreate(
            nil, Self.eventCallback(), &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Built outside the main actor: FSEvents calls it on a background queue,
    /// and a main-actor closure would trap there. The paths become Strings
    /// before hopping to the main queue.
    nonisolated private static func eventCallback() -> FSEventStreamCallback {
        { _, _, count, paths, _, _ in
            let changed = Array(UnsafeBufferPointer(
                start: paths.assumingMemoryBound(to: UnsafePointer<CChar>.self), count: count
            )).map { String(cString: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ProjectFiles.shared.filesChanged(changed) }
            }
        }
    }

    nonisolated private static func realPath(_ path: String) -> String {
        realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func filesChanged(_ paths: [String]) {
        // .git churns on every command; its changes do not alter the tree.
        let relevant = paths.filter { !$0.contains("/.git/") }
        guard !relevant.isEmpty else { return }
        // FSEvents reports real paths: /private/tmp, symlinks followed.
        let changed = Set(relevant)
        let open = [openFile].compactMap { $0 } + (root.flatMap { tabs[$0] } ?? [])
        for file in open where changed.contains(Self.realPath(file.url.path(percentEncoded: false))) {
            file.diskChanged()
        }
        refresh()
    }
}
