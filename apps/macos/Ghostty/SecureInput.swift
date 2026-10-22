import AppKit
import Carbon

/// macOS secure event input, which keeps other apps from reading keystrokes.
/// libghostty asks for it per surface, for example at a password prompt; it is
/// on while such a surface has focus and Merlix is the active app.
final class SecureInput {
    static let shared = SecureInput()

    private var wanted: Set<ObjectIdentifier> = []
    private weak var focused: TerminalSurfaceView?
    private var enabled = false

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SecureInput.shared.apply() }
            }
        }
    }

    func set(_ on: Bool?, for surface: TerminalSurfaceView) {
        let id = ObjectIdentifier(surface)
        let value = on ?? !wanted.contains(id)
        if value { wanted.insert(id) } else { wanted.remove(id) }
        apply()
    }

    func focusChanged(_ surface: TerminalSurfaceView, focused: Bool) {
        if focused {
            self.focused = surface
        } else if self.focused === surface {
            self.focused = nil
        }
        apply()
    }

    func forget(_ surface: TerminalSurfaceView) {
        wanted.remove(ObjectIdentifier(surface))
        if focused === surface { focused = nil }
        apply()
    }

    private func apply() {
        let desired = NSApp.isActive && focused.map { wanted.contains(ObjectIdentifier($0)) } == true
        guard desired != enabled else { return }
        let status = desired ? EnableSecureEventInput() : DisableSecureEventInput()
        if status == noErr { enabled = desired }
    }
}
