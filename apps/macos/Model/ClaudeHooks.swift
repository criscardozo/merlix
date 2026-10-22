import Darwin
import Foundation

/// One Claude Code hook call, decoded from the JSON body Claude posts.
struct HookEvent {
    /// The Merlix session the terminal belongs to (`X-Merlix-Session` header).
    let sessionID: UUID
    let name: String
    let claudeSessionID: String?
    let transcriptPath: String?
    let notificationType: String?
    let message: String?
    let toolName: String?
    /// Where Claude runs; tells a shell session which folder to resume in.
    let cwd: String?
    /// SessionEnd's reason ("clear" when /clear starts a new conversation).
    let reason: String?
    /// What the tool call is about, for a notification: the question and its
    /// options, the command, the file or the URL.
    let detail: String?
}

/// A tiny HTTP endpoint on 127.0.0.1 that Claude Code's http hooks post to.
/// Claude sessions started by Merlix load a settings file (`--settings`) that
/// points their hooks here, so the user's own settings stay untouched and the
/// hooks only run inside Merlix.
final class ClaudeHooks {
    static let shared = ClaudeHooks()

    /// Sent by every hook; anything else on localhost is ignored.
    let token = UUID().uuidString
    private(set) var settingsURL: URL?
    var onEvent: ((HookEvent) -> Void)?

    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]

    /// Hook events that change a session's status. SessionStart only accepts
    /// command hooks, and Merlix does not need it.
    private static let events = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "Stop", "StopFailure",
    ]

    private init() {
        Self.removeStaleFiles()
        guard let port = listen() else { return }
        self.port = port
        settingsURL = writeSettings(port: port)
    }

    private var port: UInt16?

    /// Environment for a terminal so its hooks identify themselves. The port is
    /// for the global hook script (ClaudeHookInstaller), which reads it from here.
    func environment(for sessionID: UUID) -> [String: String] {
        var environment = ["MERLIX_SESSION_ID": sessionID.uuidString, "MERLIX_HOOK_TOKEN": token]
        if let port { environment["MERLIX_HOOK_PORT"] = String(port) }
        return environment
    }

    func removeSettings() {
        if let settingsURL { try? FileManager.default.removeItem(at: settingsURL) }
    }

    // MARK: Settings file

    /// Settings files of Merlix runs that were killed rather than quit.
    private static func removeStaleFiles() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("merlix-claude-settings-") || name.hasPrefix("merlix-settings-") {
            let digits = name.drop { !$0.isNumber }.prefix { $0.isNumber }
            guard let pid = Int32(digits), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private func writeSettings(port: UInt16) -> URL? {
        let hook: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/hook",
            "headers": ["X-Merlix-Session": "$MERLIX_SESSION_ID", "X-Merlix-Token": "$MERLIX_HOOK_TOKEN"],
            "allowedEnvVars": ["MERLIX_SESSION_ID", "MERLIX_HOOK_TOKEN"],
            "timeout": 2,
        ]
        var hooks: [String: Any] = [:]
        for event in Self.events {
            hooks[event] = [["hooks": [hook]]]
        }
        // One file per running Merlix, so a second instance never redirects
        // the hooks of the first.
        let url = FileManager.default.temporaryDirectory
            .appending(path: "merlix-claude-settings-\(getpid()).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            logger.error("writing Claude settings failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Socket

    /// Binds synchronously so the port is known before the first session starts.
    private func listen() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            logger.error("hook listener failed: \(errno)")
            return nil
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { ClaudeHooks.shared.accept(on: fd) }
        }
        source.resume()
        acceptSource = source
        return UInt16(bigEndian: address.sin_port)
    }

    private func accept(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { ClaudeHooks.shared.read(fd) }
            }
            source.setCancelHandler { close(fd) }
            connections[fd] = (source, Data())
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard var connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count <= 0 {
            finish(fd, respond: false)
            return
        }
        connection.buffer.append(contentsOf: chunk[..<count])
        connections[fd] = connection
        guard let request = Self.parse(connection.buffer) else {
            if connection.buffer.count > 1 << 20 { finish(fd, respond: false) }
            return
        }
        finish(fd, respond: true)
        guard request.headers["x-merlix-token"] == token,
              let sessionID = request.headers["x-merlix-session"].flatMap(UUID.init(uuidString:)),
              let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = json["hook_event_name"] as? String
        else { return }
        onEvent?(HookEvent(
            sessionID: sessionID,
            name: name,
            claudeSessionID: json["session_id"] as? String,
            transcriptPath: json["transcript_path"] as? String,
            notificationType: json["notification_type"] as? String,
            message: json["message"] as? String,
            toolName: json["tool_name"] as? String,
            cwd: json["cwd"] as? String,
            reason: json["reason"] as? String,
            detail: Self.describe(tool: json["tool_name"] as? String, input: json["tool_input"] as? [String: Any])))
    }

    /// A short summary of a tool call. AskUserQuestion gives its first question
    /// and the option labels.
    static func describe(tool: String?, input: [String: Any]?) -> String? {
        guard let tool, let input else { return nil }
        func text(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch tool {
        case "AskUserQuestion":
            guard let question = (input["questions"] as? [[String: Any]])?.first else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return [question["question"] as? String, options.isEmpty ? nil : options.joined(separator: " · ")]
                .compactMap { $0 }.joined(separator: "\n")
        case "Bash":
            return text("command").map { String($0.prefix(300)) }
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return (text("file_path") ?? text("notebook_path")).map { ($0 as NSString).abbreviatingWithTildeInPath }
        case "WebFetch":
            return text("url")
        case "WebSearch":
            return text("query")
        case "ExitPlanMode":
            return "Plan ready for review"
        default:
            return text("description") ?? text("prompt").map { String($0.prefix(200)) }
        }
    }

    /// Replies with an empty 200, which Claude reads as "no decision".
    private func finish(_ fd: Int32, respond: Bool) {
        if respond {
            let reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = reply.withCString { Darwin.write(fd, $0, strlen($0)) }
        }
        connections.removeValue(forKey: fd)?.source.cancel()
    }

    /// A complete request: headers (lower-cased names) and a body of Content-Length bytes.
    private static func parse(_ data: Data) -> (headers: [String: String], body: Data)? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return (headers, Data(body.prefix(length)))
    }
}
