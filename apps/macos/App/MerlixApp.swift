import SwiftUI

@main
struct MerlixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.migratePreferences()
        // Launched from inside Claude Code (`! make run`), Merlix inherits that
        // session's variables, and every Claude started here would think it is a
        // child of it and stop saving transcripts. Shells re-read the user's own
        // CLAUDE_* settings from their rc files.
        let environment = ProcessInfo.processInfo.environment
        if environment["CLAUDECODE"] != nil {
            for key in environment.keys where key.hasPrefix("CLAUDE") {
                unsetenv(key)
            }
        }
    }

    /// The app's identifier changed from dev.cristian.merlix to dev.cardozo.merlix
    /// (2026-10-23). Its preferences are copied over once, so the layout, font
    /// and window size carry across.
    private static func migratePreferences() {
        let defaults = UserDefaults.standard
        let marker = "migratedFromDevCristian"
        guard defaults === UserDefaults.merlix, !defaults.bool(forKey: marker) else { return }
        let old = "dev.cristian.merlix" as CFString
        let keys = CFPreferencesCopyKeyList(old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = CFPreferencesCopyAppValue(key as CFString, old) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }

    var body: some Scene {
        Window("Merlix", id: "main") {
            RootView()
                .environment(Workspace.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands { MerlixCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Workspace.shared.restore()
        Notifier.shared.setUp()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.appearanceDidChange() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = ProjectFiles.shared.unsavedFiles
        if !unsaved.isEmpty {
            let alert = NSAlert()
            alert.messageText = unsaved.count == 1
                ? "Save changes to “\(unsaved[0].url.lastPathComponent)” before quitting?"
                : "Save changes to \(unsaved.count) files before quitting?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // A file that could not be saved keeps Merlix open, edits and all.
                for file in unsaved where !file.saveOrAlert() { return .terminateCancel }
            case .alertSecondButtonReturn:
                return .terminateCancel
            default:
                break
            }
        }
        guard GhosttyRuntime.shared.needsConfirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Merlix?"
        alert.informativeText = "Sessions are still running and will be terminated."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Workspace.shared.save()
        ClaudeHooks.shared.removeSettings()
    }

    private static func appearanceDidChange() {
        let runtime = GhosttyRuntime.shared
        runtime.appearanceDidChange()
        for session in Workspace.shared.sessions {
            for surface in session.allSurfaces { surface.setColorScheme(runtime.colorScheme) }
        }
    }
}

struct MerlixCommands: Commands {
    @AppStorage("sidebarVisible", store: .merlix) private var sidebarVisible = true
    @AppStorage("filesVisible", store: .merlix) private var filesVisible = false

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Merlix") { Self.showAbout() }
        }
        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(filesVisible ? "Hide Files" : "Show Files") { filesVisible.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .saveItem) {
            // ⌘W closes the session even when the terminal does not have focus,
            // instead of closing the only window and quitting.
            Button("Save File") { ProjectFiles.shared.currentFile?.saveOrAlert() }
                .keyboardShortcut("s")
                .disabled(ProjectFiles.shared.currentFile?.isDirty != true)
            Button("Close") { Workspace.shared.closeSelectedSession() }
                .keyboardShortcut("w")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Session") { Workspace.shared.addSessionItem() }
                .keyboardShortcut("n")
            Button("New Shell") { Workspace.shared.addSessionItem(command: "") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Add Project…") { Workspace.shared.addProjectWithPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { Self.find(.showFindInterface, terminal: "start_search") }
                .keyboardShortcut("f")
            Button("Find Next") { Self.find(.nextMatch, terminal: "navigate_search:next") }
                .keyboardShortcut("g")
            Button("Find Previous") { Self.find(.previousMatch, terminal: "navigate_search:previous") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu("Session") {
            Button("Command Palette…") { Workspace.shared.paletteVisible.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Split Right") { Workspace.shared.splitSelected(.right) }
                .keyboardShortcut("d")
            Button("Split Down") { Workspace.shared.splitSelected(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Equalize Splits") { Workspace.shared.selectedSession?.paneHost?.equalize() }
                .keyboardShortcut("=", modifiers: [.command, .control])
            Divider()
            ForEach(1...9, id: \.self) { index in
                Button("Session \(index)") { Workspace.shared.selectSession(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")))
            }
            Divider()
            Button("Previous Session") { Workspace.shared.selectSession(at: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Session") { Workspace.shared.selectSession(at: -2) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
    }

    /// Find in the file editor when it has focus, else in the terminal.
    private static func find(_ action: NSTextFinder.Action, terminal binding: String) {
        if let editor = focusedEditor() {
            let sender = NSMenuItem()
            sender.tag = action.rawValue
            editor.performTextFinderAction(sender)
            return
        }
        Workspace.shared.selectedSession?.activeSurface?.performBinding(binding)
    }

    /// The file editor with focus, also while typing in its own find bar.
    private static func focusedEditor() -> NSTextView? {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        if responder.usesFindBar { return responder }
        guard responder.isFieldEditor else { return nil }
        var view = responder.delegate as? NSView
        while let current = view {
            if let scroll = current as? NSScrollView, let text = scroll.documentView as? NSTextView, text.usesFindBar {
                return text
            }
            view = current.superview
        }
        return nil
    }

    private static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Named after Merlí, a black cat.\nClaude Code sessions in one window, on libghostty.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/criscardozo/merlix",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://github.com/criscardozo/merlix")!]))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
