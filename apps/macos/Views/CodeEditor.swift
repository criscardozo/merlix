import AppKit
import SwiftUI

/// A plain-text editor for one file: NSTextView with the terminal's font and
/// theme, no smart substitutions, the system find bar, and syntax colours.
struct CodeEditor: NSViewRepresentable {
    let file: EditedFile
    let background: TerminalBackground

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.delegate = context.coordinator
        text.isRichText = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.textContainerInset = NSSize(width: 6, height: 10)
        text.drawsBackground = false
        scroll.drawsBackground = false
        // Code reads better unwrapped: long lines scroll sideways and keep their indentation.
        scroll.hasHorizontalScroller = true
        text.isHorizontallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        context.coordinator.textView = text
        context.coordinator.load(background: background)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.file !== file || coordinator.revision != file.revision || coordinator.background != background {
            coordinator.file = file
            coordinator.load(background: background)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var file: EditedFile
        weak var textView: NSTextView?
        var revision = -1
        var background: TerminalBackground?
        private var highlighter: SyntaxHighlighter?
        private var pending: DispatchWorkItem?

        init(file: EditedFile) {
            self.file = file
        }

        /// Puts the file's text in the view and colours it.
        func load(background: TerminalBackground) {
            guard let textView else { return }
            self.background = background
            revision = file.revision
            highlighter = SyntaxHighlighter(fileExtension: file.url.pathExtension)
            let large = file.text.utf8.count > ProjectFiles.largeFile
            textView.isEditable = !large
            textView.font = Self.font
            textView.textColor = Self.colour(background.foreground)
            textView.insertionPointColor = Self.colour(background.foreground)
            textView.string = file.text
            textView.undoManager?.removeAllActions()
            if !large { highlight() }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            file.text = textView.string
            // Colour after a short pause, not on every keystroke.
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func highlight() {
            guard let textView, let storage = textView.textStorage, let background else { return }
            let base = Self.colour(background.foreground)
            guard let highlighter, storage.length <= ProjectFiles.largeFile else {
                storage.setAttributes([.foregroundColor: base, .font: Self.font], range: NSRange(location: 0, length: storage.length))
                return
            }
            highlighter.highlight(storage, colours: Self.colours(background), base: base, font: Self.font)
        }

        private static func colours(_ theme: TerminalBackground) -> [SyntaxHighlighter.Role: NSColor] {
            let palette = theme.palette
            func ansi(_ index: Int) -> NSColor? { palette.indices.contains(index) ? colour(palette[index]) : nil }
            var colours: [SyntaxHighlighter.Role: NSColor] = [
                // Comments fade the text colour: a theme's "bright black" is often too dark to read.
                .comment: colour(theme.foreground).withAlphaComponent(0.45),
            ]
            colours[.keyword] = ansi(5)
            colours[.string] = ansi(2)
            colours[.number] = ansi(3)
            colours[.type] = ansi(6)
            colours[.key] = ansi(4)
            colours[.function] = ansi(4)
            return colours
        }

        static func colour(_ value: TerminalColor) -> NSColor {
            NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
        }

        /// The terminal's font family, a little smaller to suit the panel.
        static var font: NSFont {
            let family = UserDefaults.merlix.string(forKey: TerminalSettings.fontFamilyKey).flatMap { $0.isEmpty ? nil : $0 }
                ?? TerminalSettings.ghosttyFontFamily()
            let size: CGFloat = 13
            return family.flatMap { NSFont(name: $0, size: size) ?? NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}
