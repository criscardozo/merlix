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
        text = disk
        savedText = disk
        changedOnDisk = false
        revision += 1
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
        openFile = path.flatMap { buffers[$0] }
        openError = nil
        guard let path else { return }
        refresh()
        watch(path)
    }

    func refresh() {
        guard let root else { return }
        loading = nodes.isEmpty
        refreshTask?.cancel()
        refreshTask = Task {
            let tree = await Task.detached { Self.tree(at: root) }.value
            guard !Task.isCancelled, self.root == root else { return }
            nodes = tree
            loading = false
        }
    }

    func open(_ path: String) {
        let url = URL(filePath: path)
        openError = nil
        guard let data = try? Data(contentsOf: url) else {
            openError = "Merlix could not read this file."
            return
        }
        guard data.count <= Self.largeFile * 5 else {
            openError = "This file is too large to open here."
            return
        }
        guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else {
            openError = "This looks like a binary file."
            return
        }
        openFile = EditedFile(url: url, text: text)
    }

    /// Open files with edits not yet saved, in any project.
    var unsavedFiles: [EditedFile] {
        (Array(buffers.values) + [openFile].compactMap { $0 }).filter(\.isDirty)
            .reduce(into: [EditedFile]()) { list, file in if !list.contains(where: { $0 === file }) { list.append(file) } }
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
        if let openFile, relevant.contains(openFile.url.path(percentEncoded: false)) {
            openFile.diskChanged()
        }
        refresh()
    }
}
