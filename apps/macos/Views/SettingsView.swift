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

    private let monospaced = TerminalSettings.installedMonospacedFamilies()
    private let ghosttyFont = TerminalSettings.ghosttyFontFamily()

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
                LabeledContent("More terminal settings") {
                    Button("Open ghostty.conf") { GhosttyRuntime.shared.openOverrides() }
                }
            } footer: {
                Text("Colours, spacing and everything else Ghostty supports go in Merlix's ghostty.conf. Font and size set here take precedence over it.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .onChange(of: fontFamily) { GhosttyRuntime.shared.reloadConfig() }
        .onChange(of: fontSize) { GhosttyRuntime.shared.reloadConfig() }
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
    }
}

/// What Settings stores, and the Ghostty config lines it turns into.
enum TerminalSettings {
    static let fontFamilyKey = "terminalFontFamily"
    static let fontSizeKey = "terminalFontSize"

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
        return lines.joined(separator: "\n")
    }

    static func installedMonospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let name = manager.availableMembers(ofFontFamily: family)?.first?.first as? String else { return false }
            return NSFont(name: name, size: 12)?.isFixedPitch == true
        }
    }

    /// The last font-family in the user's Ghostty config, to name the default.
    static func ghosttyFontFamily() -> String? {
        let url = URL.applicationSupportDirectory.appending(path: "com.mitchellh.ghostty/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "font-family" else { return nil }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }.last
    }
}
