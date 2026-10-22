import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Bridges libghostty clipboard requests to the system pasteboard. Only the
/// standard clipboard is supported; requests that need a confirmation prompt
/// are denied until Merlix grows a UI for them.
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

    static func deny(_ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?) {
        guard let surface = TerminalSurfaceView.from(userdata)?.surface else { return }
        ghostty_surface_deny_clipboard_request(surface, state)
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
        state: UnsafeMutableRawPointer?
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
                    confirmed: false,
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
