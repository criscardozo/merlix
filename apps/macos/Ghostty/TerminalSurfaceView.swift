import AppKit
import Carbon
import GhosttyKit

/// An NSView hosting one libghostty surface: its own PTY, renderer and input.
///
/// Keyboard, mouse and IME handling are a condensed port of Ghostty's
/// `SurfaceView_AppKit.swift` (MIT, Copyright (c) 2024 Mitchell Hashimoto,
/// Ghostty contributors). Keep the two in sync when input bugs show up.
final class TerminalSurfaceView: NSView, NSTextInputClient {
    let sessionID: UUID
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    var cellSize: CGSize = .zero
    private var focused = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var cursor: NSCursor = .iBeam
    private var pressureStage = 0
    private var screenObserver: NSObjectProtocol?

    init(sessionID: UUID, workingDirectory: String, initialInput: String?, environment: [String: String]) {
        self.sessionID = sessionID
        // Non-zero so the renderer has something to draw into before layout.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        guard let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = 0
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // libghostty copies everything it needs during ghostty_surface_new.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func cString(_ value: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(value)!
            owned.append(pointer)
            return pointer
        }

        config.working_directory = UnsafePointer(cString(workingDirectory))
        if let initialInput { config.initial_input = UnsafePointer(cString(initialInput)) }

        var env = environment.map { ghostty_env_var_s(key: cString($0.key), value: cString($0.value)) }
        surface = env.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return ghostty_surface_new(app, &config)
        }

        guard let surface else {
            logger.error("ghostty_surface_new failed")
            return
        }
        ghostty_surface_set_color_scheme(surface, GhosttyRuntime.shared.colorScheme)
        updateTrackingAreas()
        registerForDraggedTypes([.string, .fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let surface { ghostty_surface_free(surface) }
    }

    nonisolated static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    func emit(_ event: TerminalEvent) {
        GhosttyRuntime.shared.eventHandler?(event, self)
    }

    /// Frees the surface and its PTY. The view is unusable afterwards.
    func destroy() {
        SecureInput.shared.forget(self)
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    /// A process other than an idle shell is running, so closing loses work.
    var needsConfirmClose: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func setVisible(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Layout

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        guard let window else {
            // Taken out of the window (another session shown): AppKit does not
            // always resign first responder, so the surface would stay focused.
            setFocused(false)
            return
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDisplayID() }
        }
        updateDisplayID()
        viewDidChangeBackingProperties()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let size = convertToBacking(bounds.size)
        guard size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    private func updateDisplayID() {
        guard let surface,
              let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ value: Bool) {
        guard let surface, focused != value else { return }
        focused = value
        ghostty_surface_set_focus(surface, value)
        SecureInput.shared.focusChanged(self, focused: value)
        if value { emit(.focused) }
    }

    // MARK: Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_MOVE: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: cursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        default: return
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        if !focused { window?.makeFirstResponder(self) }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface,
              ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
        else { return super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, Self.button(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, Self.button(event.buttonNumber), Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, Self.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        // Negative coordinates tell libghostty the cursor left the viewport.
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        // Packed bitmask: bit 0 is precision, bits 1-3 the momentum phase.
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(Self.momentum(event.momentumPhase).rawValue) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        // Force click looks the word up, once per press, when the user has it on.
        defer { pressureStage = event.stage }
        guard pressureStage < 2, event.stage == 2,
              UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick")
        else { return }
        quickLook(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        return menu
    }

    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBinding("select_all") }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        emit(.userInput)

        // Respect configs such as macos-option-as-alt when translating the key.
        let translationFlags = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationFlags.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }

        // The original event must be reused when nothing changed: IMEs such as
        // Korean rely on object identity.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let layoutBefore = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // An input source switch shortcut was consumed by the system.
        if !markedTextBefore && layoutBefore != Self.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = committedTextAction(action, text: text)
            }
            if Self.shouldReplayAfterCommit(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: Self.ghosttyCharacters(translationEvent),
                composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        // Ghostty keybindings (copy, paste, new tab, goto tab...) win over the menu.
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            var keyEvent = Self.keyEvent(event, action: GHOSTTY_ACTION_PRESS)
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // ctrl+/ would beep; send it as ctrl+_ like Ghostty does.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"

        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            // Second pass of an unhandled command/control key: encode it.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode)
        else { return false }
        keyDown(with: finalEvent)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        var action = GHOSTTY_ACTION_RELEASE
        if Self.mods(event.modifierFlags).rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = Self.keyEvent(event, action: action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing
        if let text = text.flatMap(Self.keyEventText) {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    private func committedTextAction(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(string.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        // Outside keyDown (e.g. a layout switch mid-composition) sync right away.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// macOS asks for odd ranges here; like Ghostty, answer with the selection.
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text), attributes: terminalFontAttributes())
    }

    /// Look Up (force click or three-finger tap) on the word under the pointer.
    override func quickLook(with event: NSEvent) {
        guard let surface else { return super.quickLook(with: event) }
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &text) else { return super.quickLook(with: event) }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0 else { return super.quickLook(with: event) }
        let word = NSAttributedString(string: String(cString: text.text), attributes: terminalFontAttributes())
        showDefinition(for: word, at: NSPoint(x: text.tl_px_x, y: frame.height - text.tl_px_y))
    }

    private func terminalFontAttributes() -> [NSAttributedString.Key: Any] {
        guard let surface, let raw = ghostty_surface_quicklook_font(surface) else { return [:] }
        // libghostty hands over a +1 copy of the CTFont.
        return [.font: Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()]
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x: Double = 0
        var y: Double = 0
        var width = Double(cellSize.width)
        var height = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        // libghostty is top-left based; AppKit is bottom-left.
        let viewRect = NSRect(x: x, y: frame.height - y, width: width, height: max(height, cellSize.height))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as String: chars = value
        default: return
        }
        unmarkText()

        if var accumulator = keyTextAccumulator {
            accumulator.append(chars)
            keyTextAccumulator = accumulator
            return
        }
        // Committed text from dictation or an IME is typed input, not a paste.
        if !chars.isEmpty { _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    override func doCommand(by selector: Selector) {
        // Re-dispatch command keys that performKeyEquivalent let through so they
        // reach keyDown and get encoded for the terminal.
        if let lastPerformKeyEvent, let current = NSApp.currentEvent, lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    // MARK: Input helpers

    private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    private static func keyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = mods(event.modifierFlags)
        // Control and command never contribute to text translation.
        keyEvent.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }
        return keyEvent
    }

    /// Text for a key event, leaving control characters for libghostty to encode.
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // Function keys live in the private use area.
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    private static func keyEventText(_ text: String) -> String? {
        guard let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return text
    }

    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else {
            return false
        }
        return scalar.value < 0x20
    }

    private static func shouldReplayAfterCommit(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: return true // down, right, up
        case 0x7B: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) // left
        default: return false
        }
    }

    private static func button(_ number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_EIGHT
        case 4: GHOSTTY_MOUSE_NINE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }

    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

// MARK: Drag and drop

extension TerminalSurfaceView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    /// Dropped files arrive as shell-escaped paths, text as is. Both go through
    /// libghostty's paste path, so paste protection still applies.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        let items = sender.draggingPasteboard.pasteboardItems ?? []
        let strings = items.compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return Self.shellEscape(url.path)
            }
            return item.string(forType: .string)
        }
        let text = strings.joined(separator: " ")
        guard !text.isEmpty else { return false }
        window?.makeFirstResponder(self)
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(strlen($0))) }
        return true
    }

    /// Same characters Ghostty escapes for dropped paths.
    private static func shellEscape(_ path: String) -> String {
        var result = ""
        for character in path {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
