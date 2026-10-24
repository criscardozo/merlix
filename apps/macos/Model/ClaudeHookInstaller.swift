import Foundation

/// Optional Claude Code hooks in the user's ~/.claude/settings.json, so that
/// any `claude` run in a Merlix terminal reports to Merlix, including one typed
/// by hand. Each hook runs ~/.merlix/claude-hook.sh, which does nothing outside
/// Merlix terminals. Installing only adds entries; removing deletes only those.
nonisolated enum ClaudeHookInstaller {
    /// `MERLIX_HOME` points tests at another folder; URL.homeDirectory ignores $HOME.
    private static let home = ProcessInfo.processInfo.environment["MERLIX_HOME"]
        .map { URL(filePath: $0, directoryHint: .isDirectory) } ?? URL.homeDirectory
    static let script = home.appending(path: ".merlix/claude-hook.sh")
    static let settings = home.appending(path: ".claude/settings.json")
    /// How Merlix's entries are recognised among the user's other hooks.
    private static let marker = ".merlix/claude-hook.sh"
    private static let command = "\"$HOME/.merlix/claude-hook.sh\""

    /// Events that carry a status, plus SessionStart and SessionEnd, which tell
    /// Merlix a conversation's id and folder as soon as Claude starts and ends.
    private static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil), ("SessionEnd", nil), ("UserPromptSubmit", nil),
        ("PreToolUse", "*"), ("PostToolUse", "*"), ("PostToolUseFailure", "*"),
        ("PermissionRequest", "*"), ("Notification", nil), ("Stop", nil), ("StopFailure", nil),
    ]

    /// Reads stdin either way, so Claude never blocks writing to it, and prints
    /// nothing: Claude reads empty output as "no decision".
    private static let scriptBody = """
        #!/bin/sh
        # Merlix: passes Claude Code hook events to the Merlix window this terminal
        # belongs to. Outside Merlix terminals it does nothing.
        if [ -z "${MERLIX_HOOK_PORT-}" ] || [ -z "${MERLIX_HOOK_TOKEN-}" ] || [ -z "${MERLIX_SESSION_ID-}" ]; then
          cat >/dev/null 2>&1
          exit 0
        fi
        curl -s -m 2 -o /dev/null -X POST "http://127.0.0.1:${MERLIX_HOOK_PORT}/hook" \\
          -H "Content-Type: application/json" \\
          -H "X-Merlix-Session: ${MERLIX_SESSION_ID}" \\
          -H "X-Merlix-Token: ${MERLIX_HOOK_TOKEN}" \\
          --data-binary @- >/dev/null 2>&1
        exit 0

        """

    static var isInstalled: Bool {
        guard let hooks = readSettings()?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { entries in
            (entries as? [[String: Any]])?.contains(where: isMerlix) == true
        }
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var settings = try readSettingsForWriting()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = (hooks[event.name] as? [[String: Any]] ?? []).filter { !isMerlix($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event.name] = entries
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    static func uninstall() throws {
        var settings = try readSettingsForWriting()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (name, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isMerlix($0) }
            hooks[name] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try write(settings)
        try? FileManager.default.removeItem(at: script)
    }

    private static func isMerlix(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settings) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The settings to change: empty when there is no file yet, an error when
    /// the file is there but is not a JSON object, so it is never replaced.
    private static func readSettingsForWriting() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settings.path) else { return [:] }
        guard let object = readSettings() else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: settings.path]) }
        return object
    }

    /// Keeps a dated copy of the previous file next to it before writing, and
    /// writes through a symlink (dotfiles setups) instead of replacing it.
    private static func write(_ object: [String: Any]) throws {
        let target = settings.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            let backup = settings.deletingLastPathComponent().appending(path: "settings.json.merlix-backup-\(stamp)")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: target, to: backup)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
    }
}
