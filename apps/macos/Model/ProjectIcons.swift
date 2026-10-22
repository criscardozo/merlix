import AppKit
import Observation

/// The project sheet's working copy.
struct ProjectDraft: Identifiable {
    var project: Project
    let isNew: Bool
    /// An image chosen in the sheet, copied into Application Support on save.
    var pickedImage: URL?
    /// The group when the sheet opened, so saving only moves the project if
    /// the sheet changed it.
    let originalGroupID: UUID?
    /// For a new project: an earlier Claude conversation in its folder to pick
    /// up instead of starting a fresh one.
    var resume: ClaudeConversation?
    /// For a new project: open a plain shell instead of starting Claude.
    var startsShell = false

    init(project: Project, isNew: Bool) {
        self.project = project
        self.isNew = isNew
        originalGroupID = project.groupID
    }

    var id: UUID { project.id }

    /// A folder's name as a project name: its first letter in upper case.
    static func name(for folder: URL) -> String {
        let name = folder.lastPathComponent
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Finds and caches each project's icon: an image the user picked, else one in
/// the folder (icon.png, a favicon, an Xcode app icon…), else the avatar of the
/// GitHub owner of its origin remote. Views fall back to a letter.
@Observable
final class ProjectIcons {
    static let shared = ProjectIcons()

    private var images: [UUID: NSImage] = [:]
    @ObservationIgnored private var requested: Set<UUID> = []

    private static let directory = URL.applicationSupportDirectory.appending(path: "Merlix/icons", directoryHint: .isDirectory)

    /// Common places for a project's own icon, most specific first.
    private static let candidates = [
        "icon.png", "logo.png", "icon.svg", "logo.svg", ".github/icon.png", ".github/logo.png",
        "assets/icon.png", "assets/logo.png", "public/icon.png", "public/logo.png",
        "public/apple-touch-icon.png", "public/favicon.png", "public/favicon.svg",
        "app/icon.png", "app/icon.svg", "app/apple-icon.png", "src/app/icon.png", "src/app/icon.svg",
        "static/favicon.png", "public/favicon.ico", "app/favicon.ico", "src/app/favicon.ico", "favicon.ico",
    ]

    func image(for project: Project) -> NSImage? {
        if project.usesInitials == true { return nil }
        if let image = images[project.id] { return image }
        if !requested.contains(project.id) {
            requested.insert(project.id)
            // Not from inside a view update.
            Task { await load(project) }
        }
        return nil
    }

    func forget(_ id: UUID) {
        images[id] = nil
        requested.remove(id)
    }

    private func load(_ project: Project) async {
        if let image = await Self.resolve(path: project.path, iconFile: project.iconFile) {
            images[project.id] = image
        }
    }

    /// The icon for a folder and optional picked file, as the sheet previews it.
    static func resolve(path: String, iconFile: String?) async -> NSImage? {
        if let iconFile, let image = NSImage(contentsOfFile: iconFile) { return image }
        if let url = localIcon(in: path), let image = NSImage(contentsOf: url) { return image }
        if let owner = githubOwner(in: path) { return await githubAvatar(owner) }
        return nil
    }

    static func localIcon(in path: String) -> URL? {
        let root = URL(filePath: path, directoryHint: .isDirectory)
        let manager = FileManager.default
        for candidate in candidates {
            let url = root.appending(path: candidate)
            if manager.fileExists(atPath: url.path) { return url }
        }
        return xcodeAppIcon(in: root)
    }

    /// The largest PNG in the first AppIcon.appiconset a few levels down.
    /// Never walks the home folder or the disk root: that reaches folders
    /// macOS protects, such as the Photos library, and asks for access.
    private static func xcodeAppIcon(in root: URL) -> URL? {
        func trimmed(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let path = trimmed(root)
        guard path != trimmed(URL.homeDirectory), path != "/" else { return nil }
        let skip: Set<String> = [
            "node_modules", ".git", "build", ".build", "DerivedData", "Pods", "dist", ".next",
            "Library", "Pictures", "Movies", "Music",
        ]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return nil }
        for case let url as URL in walker {
            if walker.level > 4 || skip.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "appiconset", url.lastPathComponent.hasPrefix("AppIcon") else { continue }
            let pngs = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return pngs
                .filter { $0.pathExtension == "png" }
                .max { size(of: $0) < size(of: $1) }
        }
        return nil
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// The owner in a github.com origin remote, from .git/config (worktrees included).
    static func githubOwner(in path: String) -> String? {
        let root = URL(filePath: path, directoryHint: .isDirectory)
        var gitDirectory = root.appending(path: ".git")
        if let pointer = try? String(contentsOf: gitDirectory, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            // A worktree's gitdir is .git/worktrees/<name>; the config lives two levels up.
            gitDirectory = URL(filePath: target, relativeTo: root).deletingLastPathComponent().deletingLastPathComponent()
        }
        guard let config = try? String(contentsOf: gitDirectory.appending(path: "config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]" }
            guard inOrigin, line.hasPrefix("url") else { continue }
            let url = line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
            for prefix in ["git@github.com:", "https://github.com/", "ssh://git@github.com/"] where url.hasPrefix(prefix) {
                return url.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            }
        }
        return nil
    }

    /// Downloaded once and kept in Application Support.
    private static func githubAvatar(_ owner: String) async -> NSImage? {
        let file = directory.appending(path: "github-\(owner).png")
        if let image = NSImage(contentsOf: file) { return image }
        guard let url = URL(string: "https://github.com/\(owner).png?size=128"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data)
        else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }

    /// Copies a picked image next to the others and returns where it went.
    static func store(_ source: URL, for id: UUID) -> String? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(id.uuidString).\(source.pathExtension.lowercased())")
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return target.path
        } catch {
            return nil
        }
    }
}
