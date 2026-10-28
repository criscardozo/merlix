import Foundation
import Observation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var groupID: UUID?
    /// An image the user picked, copied into Application Support. Nil means
    /// find one in the folder or on GitHub.
    var iconFile: String?
    /// Show the initial even when the folder or GitHub has an icon.
    var usesInitials: Bool?
    /// Start its sessions when Merlix opens instead of the first time they are shown.
    var startsAtLaunch: Bool?

    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// A label in the sidebar that projects sit under.
struct ProjectGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// Optional so workspaces saved before collapsing existed still load.
    var collapsed: Bool?

    var isCollapsed: Bool { collapsed ?? false }
}

enum SessionStatus: String, Codable {
    /// Started, nothing reported yet, or the user already dealt with it.
    case idle
    /// Claude Code is running a turn (terminal progress report active).
    case working
    /// Claude Code asked for permission or input.
    case needsYou
    /// The last turn finished.
    case done
}

@Observable
final class Session: Identifiable {
    let id: UUID
    var projectID: UUID
    /// Name given by the user. Empty means "derive it from the terminal title".
    var name: String
    /// What gets typed into the shell on start. Empty opens a plain shell.
    let command: String

    var title: String?
    var pwd: String?
    var status: SessionStatus = .idle
    /// Something happened the user has not looked at yet.
    var unread = false
    var lastActivity: Date
    var isRunning = false
    /// Claude Code's own session, learnt from its hooks; used to resume it.
    var claudeSessionID: String?
    var transcriptPath: String?
    /// Where Claude runs when it was started by hand in a shell session, so a
    /// restart can go back there and resume it.
    var claudeDirectory: String?
    @ObservationIgnored var lastTranscriptScan: Date?
    /// Claude's title has shown in this run; a shell title after it means Claude exited.
    @ObservationIgnored var handClaudeRunning = false
    /// Hooks reported for this terminal, so they decide the status instead of
    /// the terminal's progress reports and notifications.
    var hooksActive = false
    /// SessionStart reached Merlix (global hooks), so it alone says which
    /// conversation the terminal runs; a `claude -p` run from inside it or
    /// in a split reports with the same terminal id and must not take over.
    @ObservationIgnored var sessionStartSeen = false

    /// The find bar over this session's terminal; nil while it is closed.
    var search: SearchState?

    /// The first terminal, where the session's command runs.
    @ObservationIgnored var surfaceView: TerminalSurfaceView?
    /// Holds the first terminal and any splits added beside it.
    @ObservationIgnored var paneHost: PaneHost?
    /// The pane that last had focus; find and ⌘W act on it.
    @ObservationIgnored weak var focusedSurface: TerminalSurfaceView?

    var activeSurface: TerminalSurfaceView? { focusedSurface ?? surfaceView }
    var allSurfaces: [TerminalSurfaceView] { paneHost?.surfaces ?? [] }

    init(
        id: UUID = UUID(), projectID: UUID, name: String, command: String, lastActivity: Date = .now,
        claudeSessionID: String? = nil, transcriptPath: String? = nil, claudeDirectory: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.command = command
        self.lastActivity = lastActivity
        self.claudeSessionID = claudeSessionID
        self.transcriptPath = transcriptPath
        self.claudeDirectory = claudeDirectory
    }

    var isClaude: Bool { command == "claude" }

    /// What to type into the shell. Claude gets Merlix's hook settings and a
    /// conversation id chosen up front (`claudeSessionID`, set by Workspace.start):
    /// resumed when its transcript exists, otherwise started under that id.
    var startCommand: String {
        // With the global hooks installed every claude reports already;
        // --settings would make each event arrive twice.
        var claude = ["claude"]
        if !ClaudeHookInstaller.isInstalled, let settings = ClaudeHooks.shared.settingsURL {
            claude += ["--settings", Self.quoted(settings.path)]
        }
        guard isClaude else {
            // A shell where Claude was running by hand: go back to its folder and resume it.
            guard let claudeSessionID, let claudeDirectory, let transcriptPath,
                  FileManager.default.fileExists(atPath: transcriptPath) else { return command }
            return "cd \(Self.quoted(claudeDirectory)) && " + (claude + ["--resume", Self.quoted(claudeSessionID)]).joined(separator: " ")
        }
        var parts = claude
        if let claudeSessionID {
            let resumable = transcriptPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            parts += [resumable ? "--resume" : "--session-id", Self.quoted(claudeSessionID)]
        }
        return parts.joined(separator: " ")
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Claude Code prefixes the terminal title with "✳" when idle and a braille
    /// spinner while working; shells do not.
    static func isClaudeTitle(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return first == "✳" || (0x2800...0x28FF).contains(first.value)
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if let title = cleanTitle, !title.isEmpty { return title }
        return command.isEmpty ? "shell" : "new session"
    }

    /// Claude Code prefixes its title with a spinner or "✳" glyph. Before it
    /// sets one, the title is the shell's command line, which is not a name.
    private var cleanTitle: String? {
        guard let title, !title.hasPrefix("clear && ") else { return nil }
        let trimmed = title.drop { !$0.isLetter && !$0.isNumber }
        return String(trimmed).trimmingCharacters(in: .whitespaces)
    }
}

@Observable
final class SearchState {
    var needle: String
    var total: Int?
    var selected: Int?
    /// Bumped to pull keyboard focus back into the find field.
    var focusRequest = 0

    init(needle: String = "") {
        self.needle = needle
    }
}
