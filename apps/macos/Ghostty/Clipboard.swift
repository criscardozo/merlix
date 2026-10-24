import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Bridges libghostty clipboard requests to the system pasteboard. Only the
/// standard clipboard is supported. A paste that could run commands asks
/// first; programs reading the clipboard (OSC 52) are always refused.
nonisolated enum Clipboard {
    static func read(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let surface = TerminalSurfaceView.from(userdata)?.surface
        else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let pasteboard = NSPasteboard.general
        var contents: [(mime: String, data: Data)] = []
        if let mimes {
            for i in 0..<mimesLen {
                guard let ptr = mimes[i] else { continue }
                let mime = String(cString: ptr)
                guard !contents.contains(where: { $0.mime == mime }),
                      let type = pasteboardType(forMime: mime),
                      let data = pasteboard.data(forType: type)
                else { continue }
                contents.append((mime, data))
            }
        }

        let available = list ? availableMimes(in: pasteboard) : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        complete(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// libghostty asks before a paste it considers unsafe: line breaks without
    /// bracketed paste, which would run each line as a command.
    static func confirm(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalSurfaceView.from(userdata), let surface = view.surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let confirm else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        // The C payload is borrowed: copy it before asking.
        let c = confirm.pointee
        var contents: [(mime: String, data: Data)] = []
        for i in 0..<(c.contents == nil ? 0 : c.contents_len) {
            let entry = c.contents[i]
            guard let mime = entry.mime else { continue }
            let data = entry.len > 0 && entry.data != nil ? Data(bytes: entry.data, count: entry.len) : Data()
            contents.append((String(cString: mime), data))
        }
        var available: [String] = []
        for i in 0..<(c.available == nil ? 0 : c.available_len) {
            if let pointer = c.available[i] { available.append(String(cString: pointer)) }
        }
        let text = contents.first { $0.mime.hasPrefix("text/plain") }.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        // libghostty keeps the request alive until it is completed or denied, on the main thread.
        nonisolated(unsafe) let state = state
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let surface = view.surface else { return }
                let alert = NSAlert()
                alert.messageText = "Paste text with line breaks?"
                alert.informativeText = "This terminal may run each line as a command.\n\n"
                    + (text.count > 400 ? String(text.prefix(400)) + "…" : text)
                alert.addButton(withTitle: "Paste")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    complete(surface, contents: contents, available: available, state: state, confirmed: true)
                } else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                }
            }
        }
    }

    static func write(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let content, len > 0 else { return }

        var items: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        for i in 0..<len {
            let entry = content[i]
            guard let mimePtr = entry.mime,
                  let type = pasteboardType(forMime: String(cString: mimePtr))
            else { continue }
            let data = entry.len > 0 && entry.data != nil ? Data(bytes: entry.data, count: entry.len) : Data()
            items.append((type, data))
        }
        guard !items.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes(items.map(\.type), owner: nil)
        for item in items {
            pasteboard.setData(item.data, forType: item.type)
        }
    }

    private static func complete(
        _ surface: ghostty_surface_t,
        contents: [(mime: String, data: Data)],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        var owned: [UnsafeMutableRawPointer] = []
        defer { owned.forEach { free($0) } }

        func copy(_ data: Data) -> UnsafeMutablePointer<CChar> {
            let buffer = malloc(max(data.count, 1))!
            data.withUnsafeBytes { if let base = $0.baseAddress { buffer.copyMemory(from: base, byteCount: $0.count) } }
            owned.append(buffer)
            return buffer.assumingMemoryBound(to: CChar.self)
        }

        func copy(_ string: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(string)!
            owned.append(UnsafeMutableRawPointer(pointer))
            return pointer
        }

        let cContents = contents.map {
            ghostty_clipboard_content_s(mime: copy($0.mime), data: copy($0.data), len: $0.data.count)
        }
        let cAvailable: [UnsafePointer<CChar>?] = available.map { UnsafePointer(copy($0)) }

        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var completion = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &completion, state)
            }
        }
    }

    private static func pasteboardType(forMime mime: String) -> NSPasteboard.PasteboardType? {
        let base = mime.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? mime
        switch base {
        case "text/plain": return .string
        case "text/html": return .html
        case "image/png": return .png
        default:
            guard let type = UTType(mimeType: base) else { return nil }
            return NSPasteboard.PasteboardType(type.identifier)
        }
    }

    private static func availableMimes(in pasteboard: NSPasteboard) -> [String] {
        (pasteboard.types ?? []).compactMap { type in
            switch type {
            case .string: "text/plain"
            case .html: "text/html"
            case .png: "image/png"
            default: UTType(type.rawValue)?.preferredMIMEType
            }
        }
    }
}
