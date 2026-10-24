import AppKit
import SwiftUI

/// Shows the selected session's terminal. One container lives for the whole
/// window; switching sessions swaps the surface view inside it so every
/// terminal keeps running in the background.
struct TerminalHost: NSViewRepresentable {
    let session: Session

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        if session.paneHost == nil { Workspace.shared.start(session) }
        guard let host = session.paneHost, let focus = session.activeSurface else { return }
        container.show(host, focusing: focus)
    }
}

final class TerminalContainerView: NSView {
    private weak var current: PaneHost?
    private weak var focusTarget: TerminalSurfaceView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The card's bottom corners. SwiftUI clipping does not reach the Metal layer.
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ host: PaneHost, focusing surface: TerminalSurfaceView) {
        guard current !== host else { return }
        current?.removeFromSuperview()
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        current = host
        focusTarget = surface
        focusCurrent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusCurrent()
    }

    private func focusCurrent() {
        // Defer so SwiftUI has finished moving focus around for the selection.
        DispatchQueue.main.async { [weak self] in
            guard let self, let target = self.focusTarget, let window = self.window else { return }
            window.makeFirstResponder(target)
        }
    }
}

/// Hides the title bar, centres the traffic lights in the taller strip the
/// sidebar controls and card header use, and makes the window non-opaque so the
/// sidebar material and Ghostty's background-opacity show what is behind it.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowProbe: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            // AppKit lays the title bar out again (and sometimes rebuilds it)
            // on many occasions, such as becoming key. Check after every window
            // update; centreTrafficLights only writes when something moved.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated { if let window { Self.centreTrafficLights(in: window) } }
            })
            // A layout pass can move them after the update; catch that too.
            if let close = window.standardWindowButton(.closeButton), let titlebar = close.superview,
               let container = titlebar.superview {
                for view in [close, titlebar, container] {
                    view.postsFrameChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification, object: view, queue: .main
                    ) { [weak window] _ in
                        MainActor.assumeIsolated { if let window { Self.centreTrafficLights(in: window) } }
                    })
                }
            }
            DispatchQueue.main.async { Self.centreTrafficLights(in: window) }
            let runtime = GhosttyRuntime.shared
            guard runtime.backgroundOpacity < 1 else { return }
            window.isOpaque = false
            window.backgroundColor = .white.withAlphaComponent(0.001)
            runtime.applyBackgroundBlur(to: window)
        }

        /// A toolbar would do this, but it swallows clicks on the SwiftUI
        /// controls drawn under it. Moving the buttons keeps the title bar
        /// transparent to clicks.
        private static func centreTrafficLights(in window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview
            else { return }
            var frame = container.frame
            frame.size.height = titleBarHeight
            frame.origin.y = window.frame.height - titleBarHeight
            // Only write changes: each write posts another frame notification.
            if container.frame != frame { container.frame = frame }
            if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                let y = ((titleBarHeight - button.frame.height) / 2).rounded()
                if button.frame.origin.y != y { button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y)) }
            }
        }
    }
}
