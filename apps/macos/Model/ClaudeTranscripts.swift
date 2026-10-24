import Foundation

/// An earlier Claude Code conversation in a folder, which a new session can resume.
struct ClaudeConversation: Identifiable, Hashable, Sendable {
    let id: String
    let transcriptPath: String
    let title: String
    let modified: Date
}

/// Reads Claude Code's transcripts: `~/.claude/projects/<folder path with
/// every other character as "-">/<session id>.jsonl`.
nonisolated enum ClaudeTranscripts {
    static func directory(for folder: String) -> URL {
        // Claude names the directory after the real path (/tmp is /private/tmp).
        // URL.resolvingSymlinksInPath strips /private instead, so use realpath.
        let real = realpath(folder, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? folder
        let trimmed = real.hasSuffix("/") && real.count > 1 ? String(real.dropLast()) : real
        // Only ASCII letters and digits survive, and anything else becomes one
        // "-" per UTF-16 unit, as in Claude's JavaScript: "año" is "a-o".
        let encoded = String(decoding: trimmed.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: unit
            default: 0x2D
            }
        }, as: UTF16.self)
        return URL.homeDirectory.appending(path: ".claude/projects/\(encoded)", directoryHint: .isDirectory)
    }

    /// Where Claude will write the transcript of conversation `id` started in `folder`.
    static func transcript(for id: String, in folder: String) -> URL {
        directory(for: folder).appending(path: "\(id).jsonl")
    }

    static func conversations(in folder: String, limit: Int = 20) -> [ClaudeConversation] {
        let directory = directory(for: folder)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit * 2)
            .compactMap { url, modified in
                guard let title = title(of: url) else { return nil }
                return ClaudeConversation(
                    id: url.deletingPathExtension().lastPathComponent,
                    transcriptPath: url.path, title: title, modified: modified)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Claude's own title for the conversation (the last `ai-title` record), else
    /// its first typed prompt. Nil when nobody ever typed anything.
    private static func title(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var aiTitle: String?
        var firstPrompt: String?
        for line in text.split(separator: "\n") {
            if line.contains("\"ai-title\""), let record = json(line), let value = record["aiTitle"] as? String {
                aiTitle = value
            } else if firstPrompt == nil, line.contains("\"type\":\"user\""),
                      let record = json(line), let message = record["message"] as? [String: Any],
                      let content = message["content"] as? String,
                      !content.hasPrefix("<"), !content.isEmpty {
                firstPrompt = content
            }
        }
        let title = aiTitle ?? firstPrompt
        return title.map { String($0.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) }
    }

    private static func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}
