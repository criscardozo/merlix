import AppKit
import SwiftUI
import UserNotifications

/// ⌘, — a standard macOS settings window with a tab per topic.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "rectangle.split.3x1") }
            TerminalPane()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            PermissionsPane()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 620)
    }
}

/// How the window is laid out, each choice shown as a small drawing.
private struct GeneralPane: View {
    @AppStorage("sidebarVisible", store: .merlix) private var sidebarVisible = true
    @AppStorage(HiddenSidebarStyle.key, store: .merlix) private var hiddenStyle = HiddenSidebarStyle.focus.rawValue
    @AppStorage(Workspace.startAllAtLaunchKey, store: .merlix) private var startAllAtLaunch = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 18) {
                    layoutOption(.sidebar, title: "Sidebar", caption: "One session, projects at the side")
                    layoutOption(.tabs, title: "Tabs", caption: "Sidebar hidden, a tab per session")
                    layoutOption(.focus, title: "Focus", caption: "Sidebar hidden, one session")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } header: {
                Text("Layout")
            } footer: {
                Text("⌃⌘S and the sidebar button switch between Sidebar and the hidden layout chosen here.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Section {
                Toggle("Start every session when Merlix opens", isOn: $startAllAtLaunch)
            } header: {
                Text("Sessions")
            } footer: {
                Text("Otherwise a session starts the first time you open it, unless its project is set to start when Merlix opens.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
    }

    private var currentLayout: LayoutPreview.Kind {
        if sidebarVisible { return .sidebar }
        return hiddenStyle == HiddenSidebarStyle.tabs.rawValue ? .tabs : .focus
    }

    private func layoutOption(_ kind: LayoutPreview.Kind, title: String, caption: String) -> some View {
        let selected = currentLayout == kind
        return Button {
            switch kind {
            case .sidebar: sidebarVisible = true
            case .tabs: hiddenStyle = HiddenSidebarStyle.tabs.rawValue; sidebarVisible = false
            case .focus: hiddenStyle = HiddenSidebarStyle.focus.rawValue; sidebarVisible = false
            }
        } label: {
            VStack(spacing: 8) {
                LayoutPreview(kind: kind)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 150)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Terminal font and size. They apply to Merlix only, on top of the user's
/// Ghostty config and Merlix's own ghostty.conf.
private struct TerminalPane: View {
    @AppStorage(TerminalSettings.fontFamilyKey, store: .merlix) private var fontFamily = ""
    @AppStorage(TerminalSettings.fontSizeKey, store: .merlix) private var fontSize = 0.0
    /// The theme pickers write their own preferences; a change to the lines reloads.
    @State private var appliedLines = TerminalSettings.configLines

    private let monospaced = TerminalSettings.installedMonospacedFamilies()
    private let ghosttyFont = TerminalSettings.ghosttyFontFamily()
    private let ghosttyTheme = TerminalSettings.ghosttyTheme()

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font", selection: choice) {
                    Text(ghosttyFont.map { "Same as Ghostty (\($0))" } ?? "Same as Ghostty").tag("")
                    Divider()
                    ForEach(TerminalSettings.presets.filter(monospaced.contains), id: \.self) { family in
                        Text(family).tag(family)
                    }
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                if choice.wrappedValue == Self.other {
                    Picker("Family", selection: $fontFamily) {
                        ForEach(others, id: \.self) { Text($0).tag($0) }
                    }
                }

                LabeledContent("Size") {
                    HStack {
                        Toggle("Same as Ghostty", isOn: sameSize)
                            .toggleStyle(.checkbox)
                        Spacer()
                        if fontSize > 0 {
                            Stepper(value: $fontSize, in: 9...32, step: 1) {
                                Text("\(Int(fontSize)) pt").monospacedDigit()
                            }
                        }
                    }
                }

                Text("The quick brown fox → 0O 1lI {}[] != =>")
                    .font(fontFamily.isEmpty ? .system(size: 13, design: .monospaced) : .custom(fontFamily, size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                ThemePicker(title: "Light", key: TerminalSettings.lightThemeKey, ghostty: ghosttyTheme.light)
                ThemePicker(title: "Dark", key: TerminalSettings.darkThemeKey, ghostty: ghosttyTheme.dark)
            } header: {
                Text("Colours")
            } footer: {
                Text("macOS switches between them with its appearance. Your own themes, in ~/.config/ghostty/themes, are listed first.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Section {
                LabeledContent("More terminal settings") {
                    Button("Open ghostty.conf") { GhosttyRuntime.shared.openOverrides() }
                }
            } footer: {
                Text("Spacing and everything else Ghostty supports go in Merlix's ghostty.conf. Font, size and colours set here take precedence over it.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .onChange(of: fontFamily) { GhosttyRuntime.shared.reloadConfig() }
        .onChange(of: fontSize) { GhosttyRuntime.shared.reloadConfig() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if TerminalSettings.configLines != appliedLines {
                appliedLines = TerminalSettings.configLines
                GhosttyRuntime.shared.reloadConfig()
            }
        }
    }

    private static let other = "\u{0}other"

    private var others: [String] {
        monospaced.filter { !TerminalSettings.presets.contains($0) }
    }

    /// The first picker: Ghostty's font, a preset, or "Other…" for the rest.
    private var choice: Binding<String> {
        Binding(
            get: {
                fontFamily.isEmpty || TerminalSettings.presets.contains(fontFamily) ? fontFamily : Self.other
            },
            set: { value in
                if value == Self.other {
                    if TerminalSettings.presets.contains(fontFamily) || fontFamily.isEmpty {
                        fontFamily = others.first ?? ""
                    }
                } else {
                    fontFamily = value
                }
            })
    }

    private var sameSize: Binding<Bool> {
        Binding(
            get: { fontSize == 0 },
            set: { fontSize = $0 ? 0 : 15 })
    }
}

/// A Ghostty theme for one appearance: Ghostty's own, one of the user's, or
/// "Other…" for the themes that come with Ghostty.
private struct ThemePicker: View {
    let title: String
    let ghostty: String?
    @AppStorage private var theme: String

    private let mine = TerminalSettings.userThemes()
    private let bundled = TerminalSettings.bundledThemes()
    private static let other = "\u{0}other"

    init(title: String, key: String, ghostty: String?) {
        self.title = title
        self.ghostty = ghostty
        _theme = AppStorage(wrappedValue: "", key, store: .merlix)
    }

    var body: some View {
        Picker(title, selection: choice) {
            Text(ghostty.map { "Same as Ghostty (\($0))" } ?? "Same as Ghostty").tag("")
            if !mine.isEmpty {
                Divider()
                ForEach(mine, id: \.self) { Text($0).tag($0) }
            }
            Divider()
            Text("Other…").tag(Self.other)
        }
        if choice.wrappedValue == Self.other {
            Picker("\(title) theme", selection: $theme) {
                ForEach(bundled, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private var choice: Binding<String> {
        Binding(
            get: { theme.isEmpty || mine.contains(theme) ? theme : Self.other },
            set: { value in
                if value == Self.other {
                    if theme.isEmpty || mine.contains(theme) { theme = bundled.first ?? "" }
                } else {
                    theme = value
                }
            })
    }
}

/// What Merlix may need from macOS, whether it has it, and a way to ask again.
private struct PermissionsPane: View {
    @State private var notifications: UNAuthorizationStatus?
    @State private var hooksInstalled = ClaudeHookInstaller.isInstalled
    @State private var hookError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        if hooksInstalled {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Remove") { change(ClaudeHookInstaller.uninstall) }
                        } else {
                            Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
                            Button("Install") { change(ClaudeHookInstaller.install) }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code hooks")
                        Text("Lets any claude in a Merlix terminal report its status and conversation, including one typed by hand.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text(hookError ?? "Adds entries to ~/.claude/settings.json, next to your own hooks, after saving a backup beside it. They run ~/.merlix/claude-hook.sh, which does nothing outside Merlix. Remove takes out only Merlix's entries.")
                    .foregroundStyle(hookError == nil ? .secondary : Color.red)
                    .font(.footnote)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        status
                        switch notifications {
                        case .notDetermined:
                            Button("Ask") { Task { await Notifier.shared.requestAuthorization(); await refresh() } }
                        case .denied:
                            Button("Open System Settings") { Notifier.openSystemSettings() }
                        default:
                            EmptyView()
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications")
                        Text("Tells you when a session needs you while you are looking at another one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("macOS")
            } footer: {
                Text("macOS asks only once. After that, changes are made in System Settings.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch notifications {
        case .authorized, .provisional, .ephemeral:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Label("Off", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .notDetermined:
            Label("Not asked yet", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        hooksInstalled = ClaudeHookInstaller.isInstalled
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        hooksInstalled = ClaudeHookInstaller.isInstalled
    }
}

/// What Settings stores, and the Ghostty config lines it turns into.
enum TerminalSettings {
    static let fontFamilyKey = "terminalFontFamily"
    static let fontSizeKey = "terminalFontSize"
    static let lightThemeKey = "terminalThemeLight"
    static let darkThemeKey = "terminalThemeDark"

    static let presets = ["Hack", "JetBrains Mono NL", "JetBrains Mono", "Menlo"]

    /// Ghostty config lines for the current choices; empty when nothing is set.
    static var configLines: String {
        let defaults = UserDefaults.merlix
        var lines: [String] = []
        if let family = defaults.string(forKey: fontFamilyKey), !family.isEmpty {
            // font-family is a fallback list; reset it so this one replaces it.
            lines += ["font-family = \"\"", "font-family = \"\(family)\""]
        }
        let size = defaults.double(forKey: fontSizeKey)
        if size > 0 { lines.append("font-size = \(Int(size))") }
        // Ghostty wants both sides in one value; a side left alone keeps the
        // theme the config files give it.
        let light = defaults.string(forKey: lightThemeKey).flatMap { $0.isEmpty ? nil : $0 }
        let dark = defaults.string(forKey: darkThemeKey).flatMap { $0.isEmpty ? nil : $0 }
        if light != nil || dark != nil {
            let current = configuredTheme()
            let pair = (light ?? current.light, dark ?? current.dark)
            switch pair {
            case let (light?, dark?): lines.append("theme = light:\(light),dark:\(dark)")
            case let (light?, nil): lines.append("theme = \(light)")
            case let (nil, dark?): lines.append("theme = \(dark)")
            default: break
            }
        }
        return lines.joined(separator: "\n")
    }

    static func installedMonospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let name = manager.availableMembers(ofFontFamily: family)?.first?.first as? String else { return false }
            return NSFont(name: name, size: 12)?.isFixedPitch == true
        }
    }

    /// The last font-family in Ghostty's config files, to name the default.
    static func ghosttyFontFamily() -> String? {
        lastValue(of: "font-family", in: ghosttyConfigFiles)
    }

    /// The light and dark themes Ghostty's own config files set.
    static func ghosttyTheme() -> (light: String?, dark: String?) {
        parseTheme(lastValue(of: "theme", in: ghosttyConfigFiles))
    }

    /// The themes before Settings applies: Ghostty's files, then Merlix's ghostty.conf.
    private static func configuredTheme() -> (light: String?, dark: String?) {
        parseTheme(lastValue(of: "theme", in: ghosttyConfigFiles + [GhosttyRuntime.overridesURL]))
    }

    /// `light:A,dark:B`, or one theme for both.
    private static func parseTheme(_ value: String?) -> (light: String?, dark: String?) {
        guard let value else { return (nil, nil) }
        var light: String?
        var dark: String?
        for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("light:") { light = String(part.dropFirst(6)) }
            else if part.hasPrefix("dark:") { dark = String(part.dropFirst(5)) }
        }
        return light == nil && dark == nil ? (value, value) : (light, dark)
    }

    /// Ghostty's config files in the order it loads them (XDG first, then
    /// Application Support, which wins).
    private static var ghosttyConfigFiles: [URL] {
        let support = URL.applicationSupportDirectory.appending(path: "com.mitchellh.ghostty", directoryHint: .isDirectory)
        return [xdgConfig.appending(path: "ghostty"), support].flatMap { [$0.appending(path: "config"), $0.appending(path: "config.ghostty")] }
    }

    private static var xdgConfig: URL {
        ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
    }

    private static func lastValue(of key: String, in files: [URL]) -> String? {
        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        return text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { return nil }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }.last
    }

    /// Themes in ~/.config/ghostty/themes, where Ghostty looks for the user's own.
    static func userThemes() -> [String] {
        themes(in: xdgConfig.appending(path: "ghostty/themes", directoryHint: .isDirectory))
    }

    /// The themes that come with Ghostty, in the app's resources.
    static func bundledThemes() -> [String] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return themes(in: resources.appending(path: "ghostty/themes", directoryHint: .isDirectory))
    }

    private static func themes(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.resolvingSymlinksInPath().path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
