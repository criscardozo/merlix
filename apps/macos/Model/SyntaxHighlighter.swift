import AppKit

/// Simple, rule-based colouring for the file editor: comments and strings in
/// one left-to-right pass (so a "//" inside a string stays a string), then
/// keywords, numbers, types and keys outside them. Not a parser; good enough
/// to read code at a glance. Colours come from the terminal theme's palette.
struct SyntaxHighlighter {
    enum Role { case comment, string, keyword, number, type, key, function }

    private let opaque: [NSRegularExpression]
    private let rules: [(NSRegularExpression, Role)]

    init?(fileExtension: String) {
        guard let language = Self.language(for: fileExtension.lowercased()) else { return nil }
        opaque = language.opaque.compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
        rules = language.rules.compactMap { pattern, role in
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])).map { ($0, role) }
        }
    }

    /// Colours the whole text. Opaque patterns alternate as (comment, string, …)
    /// groups: group 1 is a comment, group 2 a string.
    func highlight(_ storage: NSTextStorage, colours: [Role: NSColor], base: NSColor, font: NSFont) {
        let text = storage.string as NSString
        let all = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: base, .font: font], range: all)
        var covered = IndexSet()
        for regex in opaque {
            regex.enumerateMatches(in: storage.string, range: all) { match, _, _ in
                guard let match else { return }
                for (group, role) in [(1, Role.comment), (2, Role.string)] where match.numberOfRanges > group {
                    let range = match.range(at: group)
                    guard range.location != NSNotFound, range.length > 0,
                          !covered.intersects(integersIn: range.location..<range.location + range.length)
                    else { continue }
                    covered.insert(integersIn: range.location..<range.location + range.length)
                    if let colour = colours[role] { storage.addAttribute(.foregroundColor, value: colour, range: range) }
                }
            }
        }
        for (regex, role) in rules {
            guard let colour = colours[role] else { continue }
            regex.enumerateMatches(in: storage.string, range: all) { match, _, _ in
                guard let match else { return }
                let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? match.range(at: 1) : match.range
                guard range.length > 0, !covered.intersects(integersIn: range.location..<range.location + range.length)
                else { return }
                // The first rule wins: `Self` is a keyword, not a type.
                covered.insert(integersIn: range.location..<range.location + range.length)
                storage.addAttribute(.foregroundColor, value: colour, range: range)
            }
        }
        storage.endEditing()
    }

    // MARK: Languages

    private struct Language {
        var opaque: [String]
        var rules: [(String, Role)]
    }

    private static let cComments = #"(//[^\n]*|/\*[\s\S]*?\*/)"#
    private static let hashComments = #"(#[^\n]*)"#
    /// Shell and YAML: only after a space or at the start, so `$#` and `${#x}` are not comments.
    private static let spacedHashComments = #"((?<![^\s])#[^\n]*)"#
    private static let quoted = #"("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#
    private static let number = (#"\b(0x[0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, Role.number)
    private static let capitalised = (#"\b([A-Z][A-Za-z0-9_]*)\b"#, Role.type)
    private static let call = (#"\b([a-z_][A-Za-z0-9_]*)(?=\()"#, Role.function)

    private static func words(_ list: String) -> (String, Role) {
        (#"\b("# + list.split(separator: " ").joined(separator: "|") + #")\b"#, .keyword)
    }

    private static func language(for ext: String) -> Language? {
        switch ext {
        case "swift":
            return Language(
                opaque: [cComments + #"|("""[\s\S]*?"""|"(?:\\.|[^"\\\n])*")"#],
                rules: [
                    words("actor as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is isolated lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while any"),
                    (#"(@[A-Za-z_]+)"#, .function), capitalised, call, number,
                ])
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts":
            return Language(
                opaque: [cComments + #"|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)"#],
                rules: [
                    words("abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let new null of private protected public readonly return satisfies set static super switch this throw true try type typeof undefined var void while with yield"),
                    capitalised, call, number,
                ])
        case "json", "jsonc":
            return Language(
                // Keys match the last, uncaptured alternative, so the key rule colours them.
                opaque: [cComments + #"|("(?:\\.|[^"\\\n])*"(?!\s*:))|"(?:\\.|[^"\\\n])*"(?=\s*:)"#],
                rules: [(#"("(?:\\.|[^"\\\n])*")(?=\s*:)"#, .key), words("true false null"), number])
        case "py":
            return Language(
                opaque: [hashComments + #"|("""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#],
                rules: [
                    words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return self True try while with yield match case"),
                    (#"(@[A-Za-z_.]+)"#, .function), capitalised, call, number,
                ])
        case "sh", "bash", "zsh", "fish", "command":
            return Language(
                opaque: [spacedHashComments + "|" + quoted],
                rules: [
                    words("if then else elif fi for in do done while until case esac function return local export source set unset echo exit"),
                    (#"(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)"#, .type), number,
                ])
        case "yml", "yaml", "toml", "ini", "conf", "env":
            return Language(
                opaque: [spacedHashComments + "|" + quoted],
                rules: [(#"^\s*-?\s*([A-Za-z0-9_.\-]+)\s*[:=]"#, .key), (#"^\s*(\[[^\]]+\])"#, .type),
                        words("true false null yes no on off"), number])
        case "md", "markdown":
            return Language(
                opaque: [#"(<!--[\s\S]*?-->)|(```[\s\S]*?```|`[^`\n]+`)"#],
                rules: [(#"^(#{1,6} .*)$"#, .keyword), (#"(\*\*[^*\n]+\*\*|__[^_\n]+__)"#, .type),
                        (#"(\[[^\]\n]+\]\([^)\n]+\))"#, .function), (#"^\s*([-*+]|\d+\.) "#, .number)])
        case "css", "scss", "less":
            return Language(
                opaque: [cComments + "|" + quoted],
                rules: [(#"([A-Za-z-]+)(?=\s*:[^:])"#, .key), (#"(#[0-9a-fA-F]{3,8})\b"#, .number),
                        (#"(\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?)\b"#, .number), (#"([.#][A-Za-z_-][\w-]*)"#, .type)])
        case "html", "htm", "xml", "svg", "plist", "vue":
            return Language(
                opaque: [#"(<!--[\s\S]*?-->)|("[^"\n]*"|'[^'\n]*')"#],
                rules: [(#"</?([A-Za-z][\w:-]*)"#, .keyword), (#"\s([A-Za-z_:][\w:.-]*)(?==)"#, .key)])
        case "go", "rs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "dart", "zig", "scala", "php":
            return Language(
                opaque: [cComments + "|" + quoted],
                rules: [
                    words("abstract async await bool break case catch char class const continue default defer do double else enum extends extern false final finally float fn for func go if impl implements import in int interface let long loop match mod mut namespace new nil null package private protected pub public return self static struct super switch this throw throws trait true try type typedef union unsafe use var void volatile where while"),
                    capitalised, call, number,
                ])
        case "rb":
            return Language(
                opaque: [hashComments + "|" + quoted],
                rules: [words("alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield"),
                        (#"(:[A-Za-z_]\w*)"#, .type), capitalised, number])
        case "sql":
            return Language(
                opaque: [#"(--[^\n]*|/\*[\s\S]*?\*/)|('(?:''|[^'])*')"#],
                rules: [(#"(?i)\b(select|from|where|and|or|not|insert|into|values|update|set|delete|create|table|index|view|drop|alter|add|join|left|right|inner|outer|on|group|by|order|having|limit|offset|as|distinct|null|is|in|primary|key|foreign|references|default|unique|union|all|case|when|then|else|end)\b"#, .keyword), number])
        default:
            return nil
        }
    }
}
