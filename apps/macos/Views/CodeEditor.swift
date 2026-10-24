import AppKit
import SwiftUI

/// A plain-text editor for one file: NSTextView with the terminal's font and
/// theme, no smart substitutions, the system find bar, and syntax colours.
struct CodeEditor: NSViewRepresentable {
    let file: EditedFile
    let background: TerminalBackground
    var lineNumbers = false

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    func makeNSView(context: Context) -> NSView {
        // TextKit 1: the line number ruler places lines through its layout manager.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let text = NSTextView(usingTextLayoutManager: false)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.minSize = NSSize(width: 0, height: 0)
        scroll.documentView = text
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
        guard lineNumbers else { return scroll }
        let gutter = LineNumberGutter(textView: text, scrollView: scroll)
        context.coordinator.ruler = gutter
        gutter.update(colour: Coordinator.colour(background.foreground), font: Coordinator.font)
        return EditorWithGutter(gutter: gutter, scroll: scroll)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.file !== file || coordinator.revision != file.revision {
            coordinator.file = file
            coordinator.load(background: background)
        } else if coordinator.background != background {
            // A theme change: restyle in place, keeping the selection and undo.
            coordinator.restyle(background: background)
        }
        if let line = file.revealLine {
            // After this update: the view must be laid out to scroll, and state can't change mid-update.
            DispatchQueue.main.async {
                coordinator.reveal(line: line)
                file.revealLine = nil
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var file: EditedFile
        weak var textView: NSTextView?
        weak var ruler: LineNumberGutter?
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
            ruler?.update(colour: Self.colour(background.foreground), font: Self.font)
            if !large { highlight() }
        }

        func restyle(background: TerminalBackground) {
            guard let textView else { return }
            self.background = background
            textView.font = Self.font
            textView.textColor = Self.colour(background.foreground)
            textView.insertionPointColor = Self.colour(background.foreground)
            ruler?.update(colour: Self.colour(background.foreground), font: Self.font)
            highlight()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { file.undoManager }

        /// Selects line `line` (1-based) and scrolls it into the middle of the view.
        func reveal(line: Int) {
            guard let textView else { return }
            let text = textView.string as NSString
            var location = 0
            var current = 1
            while current < line, location < text.length {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                current += 1
            }
            let range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            if let layout = textView.layoutManager, let container = textView.textContainer,
               let clip = textView.enclosingScrollView?.contentView {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let y = line.midY + textView.textContainerOrigin.y - clip.bounds.height / 2
                let maxY = max(0, textView.frame.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            textView.showFindIndicator(for: range)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            file.text = textView.string
            ruler?.textChanged()
            // Colour after a short pause, not on every keystroke.
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlight() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        private func highlight() {
            // Recolouring mid-composition (dead keys, input methods) would drop its underline.
            guard let textView, !textView.hasMarkedText(), let storage = textView.textStorage, let background else { return }
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

/// The line number column and the editor's scroll view side by side.
final class EditorWithGutter: NSView {
    private let gutter: LineNumberGutter
    private let scroll: NSScrollView

    init(gutter: LineNumberGutter, scroll: NSScrollView) {
        self.gutter = gutter
        self.scroll = scroll
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scroll)
        gutter.onWidthChange = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let width = gutter.width
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}

/// Line numbers for a TextKit 1 text view, following its scrolling. Keeps
/// where each line starts, so drawing only looks up the lines on screen.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var lineStarts: [Int] = [0]
    private var colour = NSColor.secondaryLabelColor
    private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private(set) var width: CGFloat = 40
    var onWidthChange: (() -> Void)?

    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(colour: NSColor, font: NSFont) {
        self.colour = colour.withAlphaComponent(0.4)
        self.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
        textChanged()
    }

    func textChanged() {
        let text = (textView?.string ?? "") as NSString
        var starts = [0]
        var index = 0
        while index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            if index < text.length || (index == text.length && text.character(at: text.length - 1) == 10) {
                starts.append(index)
            }
        }
        lineStarts = starts
        let digit = ("8" as NSString).size(withAttributes: [.font: font]).width
        let newWidth = (CGFloat(max(3, String(starts.count).count)) * digit + 18).rounded()
        if newWidth != width {
            width = newWidth
            onWidthChange?()
        }
        needsDisplay = true
    }

    @objc private func scrolled() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let scrollView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = scrollView.contentView.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // The first line on screen, by binary search over the line starts.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= characters.location { low = middle } else { high = middle - 1 }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let top = textView.textContainerOrigin.y - visible.minY
        let length = (textView.string as NSString).length
        var line = low
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let fragment = start < length
                ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
                : layout.extraLineFragmentRect
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: width - size.width - 8, y: top + fragment.minY + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
        }
    }
}
