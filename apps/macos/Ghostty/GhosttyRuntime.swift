import AppKit
import GhosttyKit
import OSLog

nonisolated let logger = Logger(subsystem: "dev.cristian.merlix", category: "ghostty")

/// What a terminal surface reports to the rest of the app. libghostty actions are
/// translated into these so nothing outside `Ghostty/` touches the C API.
nonisolated enum TerminalEvent: Sendable {
    case title(String)
    case pwd(String)
    case progress(TerminalProgress)
    case notification(title: String, body: String)
    case bell
    case userInput
    /// ⌘-click on a link Ghostty found: a URL, or a file path from the output.
    case openLink(String)
    case focused
    case newSession
    case gotoSession(Int32)
    case closeRequested(processAlive: Bool)
    case commandPalette
    case searchStarted(needle: String?)
    case searchEnded
    case searchTotal(Int?)
    case searchSelected(Int?)
    case openSettings
    case newSplit(SplitDirection)
    case gotoSplit(SplitTarget)
    case resizeSplit(SplitTarget, amount: Int)
    case equalizeSplits
}

nonisolated enum SplitDirection: Sendable {
    case right, down, left, up
}

nonisolated enum SplitTarget: Sendable {
    case previous, next, up, left, down, right
}

nonisolated enum TerminalProgress: Sendable {
    case working, paused, failed, finished
}

/// The terminal's background colour for the current light or dark theme, so the
/// chrome around a surface can match it.
nonisolated struct TerminalBackground: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double
    /// The theme's text colour and its 16 ANSI colours, for the file editor.
    var foreground = TerminalColor(red: 0.85, green: 0.85, blue: 0.85)
    var palette: [TerminalColor] = []
}

nonisolated struct TerminalColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    fileprivate init(_ color: ghostty_config_color_s) {
        self.init(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }
}

/// A libghostty action decoded off the C structs, safe to hand to the main actor.
nonisolated private enum RuntimeAction: Sendable {
    case quit
    case surface(TerminalEvent)
    case mouseShape(UInt32)
    case hideMouse
    case cellSize(CGSize)
    case openURL(String)
    case openConfig
    case reloadConfig
    case secureInput(Bool?)
    case background(TerminalBackground)
    case acknowledge
}

/// Owns the single libghostty app instance and its configuration. The config is
/// the user's own Ghostty config (~/Library/Application Support/com.mitchellh.ghostty
/// or ~/.config/ghostty), so Merlix looks exactly like their Ghostty.
@Observable
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    @ObservationIgnored private(set) var app: ghostty_app_t?
    @ObservationIgnored private(set) var config: ghostty_config_t?

    /// Receives every surface event, with the surface it came from when there is one.
    @ObservationIgnored var eventHandler: ((TerminalEvent, TerminalSurfaceView?) -> Void)?

    private(set) var background = TerminalBackground(red: 0.12, green: 0.12, blue: 0.12, opacity: 1)

    private init() {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            logger.critical("ghostty_init failed")
            return
        }

        config = Self.loadConfig()
        guard let config else { return }
        background = Self.background(of: config)

        var runtime = Self.runtimeConfig()
        guard let app = ghostty_app_new(&runtime, config) else {
            logger.critical("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        observeApplication()
        // The app-level config starts in the light theme. Telling it the real
        // scheme makes it report the matching config (and background) back.
        // Deferred: libghostty calls back synchronously, and `shared` is
        // still being initialised here.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { GhosttyRuntime.shared.appearanceDidChange() }
        }
    }

    var backgroundOpacity: Double { background.opacity }

    nonisolated private static func background(of config: ghostty_config_t) -> TerminalBackground {
        var color = ghostty_config_color_s()
        var opacity: Double = 1
        let colorKey = "background"
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &color, colorKey, UInt(colorKey.utf8.count))
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.utf8.count))
        var foreground = ghostty_config_color_s(r: 217, g: 217, b: 217)
        let foregroundKey = "foreground"
        _ = ghostty_config_get(config, &foreground, foregroundKey, UInt(foregroundKey.utf8.count))
        var palette = ghostty_config_palette_s()
        let paletteKey = "palette"
        _ = ghostty_config_get(config, &palette, paletteKey, UInt(paletteKey.utf8.count))
        let ansi = withUnsafeBytes(of: palette.colors) { raw in
            Array(raw.bindMemory(to: ghostty_config_color_s.self).prefix(16)).map(TerminalColor.init)
        }
        return TerminalBackground(
            red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255,
            opacity: opacity, foreground: TerminalColor(foreground), palette: ansi)
    }

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    var colorScheme: ghostty_color_scheme_e {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK
            : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func appearanceDidChange() {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, colorScheme)
    }

    func applyBackgroundBlur(to window: NSWindow) {
        guard let app else { return }
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    // MARK: Config

    /// Settings that apply to Merlix only, on top of the user's Ghostty config.
    static let overridesURL = URL.applicationSupportDirectory
        .appending(path: "Merlix/ghostty.conf", directoryHint: .notDirectory)

    private static func loadConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        if FileManager.default.fileExists(atPath: overridesURL.path) {
            ghostty_config_load_file(config, overridesURL.path)
        }
        // Settings come last, so the font picked there wins over ghostty.conf.
        let settings = TerminalSettings.configLines
        if !settings.isEmpty {
            let url = FileManager.default.temporaryDirectory.appending(path: "merlix-settings-\(getpid()).conf")
            if (try? settings.write(to: url, atomically: true, encoding: .utf8)) != nil {
                ghostty_config_load_file(config, url.path)
            }
        }
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, i)
            if let message = diagnostic.message {
                logger.warning("config: \(String(cString: message), privacy: .public)")
            }
        }
        return config
    }

    /// Opens Merlix's own terminal settings, creating the file with a short
    /// explanation the first time.
    func openOverrides() {
        let url = Self.overridesURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = """
                # Merlix-only terminal settings, applied on top of your Ghostty config.
                # Same syntax as Ghostty. Reload with ⇧⌘, or from the command palette.

                """
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    func reloadConfig() {
        guard let app, let fresh = Self.loadConfig() else { return }
        ghostty_app_update_config(app, fresh)
        if let config { ghostty_config_free(config) }
        config = fresh
    }

    private func observeApplication() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyRuntime.shared.setAppFocus(true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyRuntime.shared.setAppFocus(false) }
        }
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) }
            }
        }
    }

    private func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: Callbacks

    /// The C callbacks must be nonisolated: libghostty calls wakeup from its IO
    /// thread. Everything else arrives on the main thread during a tick or a
    /// surface call, which `assumeIsolated` checks.
    nonisolated private static func runtimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GhosttyRuntime.shared.tick() }
                }
            },
            action_cb: { _, target, action in
                guard let (view, decoded) = GhosttyRuntime.decode(action, target: target) else { return false }
                return MainActor.assumeIsolated { GhosttyRuntime.shared.perform(decoded, on: view) }
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                Clipboard.read(userdata, location: location, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                Clipboard.deny(userdata, state: state)
            },
            write_clipboard_cb: { _, location, content, len, confirm in
                Clipboard.write(location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                let view = TerminalSurfaceView.from(userdata)
                MainActor.assumeIsolated { view?.emit(.closeRequested(processAlive: processAlive)) }
            }
        )
    }

    /// Reads what we need out of the C action. Returns nil for actions Merlix
    /// does not handle, which tells libghostty they were not performed.
    nonisolated private static func decode(
        _ action: ghostty_action_s,
        target: ghostty_target_s
    ) -> (TerminalSurfaceView?, RuntimeAction)? {
        var view: TerminalSurfaceView?
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            view = TerminalSurfaceView.from(ghostty_surface_userdata(surface))
        }

        let decoded: RuntimeAction
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            decoded = .quit
        case GHOSTTY_ACTION_NEW_WINDOW, GHOSTTY_ACTION_NEW_TAB:
            decoded = .surface(.newSession)
        case GHOSTTY_ACTION_GOTO_TAB:
            decoded = .surface(.gotoSession(action.action.goto_tab.rawValue))
        case GHOSTTY_ACTION_CLOSE_TAB:
            decoded = .surface(.closeRequested(processAlive: true))
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return nil }
            decoded = .surface(.title(String(cString: title)))
        case GHOSTTY_ACTION_PWD:
            guard let pwd = action.action.pwd.pwd else { return nil }
            decoded = .surface(.pwd(String(cString: pwd)))
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            decoded = .surface(.progress(progress(action.action.progress_report.state)))
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            decoded = .surface(.notification(
                title: n.title.map { String(cString: $0) } ?? "",
                body: n.body.map { String(cString: $0) } ?? ""))
        case GHOSTTY_ACTION_RING_BELL:
            decoded = .surface(.bell)
        case GHOSTTY_ACTION_NEW_SPLIT:
            let direction: SplitDirection = switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
            case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
            case GHOSTTY_SPLIT_DIRECTION_UP: .up
            default: .right
            }
            decoded = .surface(.newSplit(direction))
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let target = splitTarget(goto: action.action.goto_split) else { return nil }
            decoded = .surface(.gotoSplit(target))
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resize = action.action.resize_split
            let target: SplitTarget = switch resize.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: .left
            default: .right
            }
            decoded = .surface(.resizeSplit(target, amount: Int(resize.amount)))
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            decoded = .surface(.equalizeSplits)
        case GHOSTTY_ACTION_SECURE_INPUT:
            let on: Bool? = switch action.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON: true
            case GHOSTTY_SECURE_INPUT_OFF: false
            default: nil
            }
            decoded = .secureInput(on)
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            decoded = .surface(.commandPalette)
        case GHOSTTY_ACTION_START_SEARCH:
            decoded = .surface(.searchStarted(needle: action.action.start_search.needle.map { String(cString: $0) }))
        case GHOSTTY_ACTION_END_SEARCH:
            decoded = .surface(.searchEnded)
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            decoded = .surface(.searchTotal(total >= 0 ? Int(total) : nil))
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            decoded = .surface(.searchSelected(selected >= 0 ? Int(selected) : nil))
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            decoded = .mouseShape(action.action.mouse_shape.rawValue)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN else { return (view, .acknowledge) }
            decoded = .hideMouse
        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            decoded = .cellSize(CGSize(width: Double(size.width), height: Double(size.height)))
        case GHOSTTY_ACTION_OPEN_URL:
            let open = action.action.open_url
            guard let ptr = open.url else { return nil }
            decoded = .openURL(String(decoding: Data(bytes: ptr, count: Int(open.len)), as: UTF8.self))
        case GHOSTTY_ACTION_OPEN_CONFIG:
            decoded = .openConfig
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            decoded = .reloadConfig
        case GHOSTTY_ACTION_CONFIG_CHANGE where target.tag == GHOSTTY_TARGET_APP:
            guard let config = action.action.config_change.config else { return (view, .acknowledge) }
            decoded = .background(background(of: config))
        case GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RENDERER_HEALTH:
            decoded = .acknowledge
        default:
            return nil
        }
        return (view, decoded)
    }

    nonisolated private static func splitTarget(goto value: ghostty_action_goto_split_e) -> SplitTarget? {
        switch value {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: .next
        case GHOSTTY_GOTO_SPLIT_UP: .up
        case GHOSTTY_GOTO_SPLIT_LEFT: .left
        case GHOSTTY_GOTO_SPLIT_DOWN: .down
        case GHOSTTY_GOTO_SPLIT_RIGHT: .right
        default: nil
        }
    }

    nonisolated private static func progress(_ state: ghostty_action_progress_report_state_e) -> TerminalProgress {
        switch state {
        case GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_INDETERMINATE: .working
        case GHOSTTY_PROGRESS_STATE_PAUSE: .paused
        case GHOSTTY_PROGRESS_STATE_ERROR: .failed
        default: .finished
        }
    }

    private func perform(_ action: RuntimeAction, on view: TerminalSurfaceView?) -> Bool {
        switch action {
        case .quit:
            NSApp.terminate(nil)
        case .surface(let event):
            switch event {
            case .newSession, .gotoSession, .commandPalette:
                // Valid with or without a surface target.
                eventHandler?(event, view)
            default:
                guard let view else { return false }
                view.emit(event)
            }
        case .mouseShape(let raw):
            view?.setCursorShape(ghostty_action_mouse_shape_e(raw))
        case .hideMouse:
            NSCursor.setHiddenUntilMouseMoves(true)
        case .cellSize(let size):
            view?.cellSize = size
        case .openURL(let string):
            if let view {
                view.emit(.openLink(string))
            } else if let url = URL(string: string) {
                NSWorkspace.shared.open(url)
            }
        case .openConfig:
            // Ghostty's ⌘, opens Merlix's Settings rather than Ghostty's config file.
            eventHandler?(.openSettings, view)
        case .reloadConfig:
            reloadConfig()
        case .background(let value):
            background = value
        case .secureInput(let on):
            guard let view else { return false }
            SecureInput.shared.set(on, for: view)
        case .acknowledge:
            break
        }
        return true
    }
}
