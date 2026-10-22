import AppKit

/// One session's terminals: a single surface, or a tree of split views with a
/// surface at each leaf. The host stays the same view for the session's whole
/// life, so the window can swap sessions without disturbing their splits.
final class PaneHost: NSView {
    init(_ surface: TerminalSurfaceView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        place(surface, in: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Every surface, in reading order: left to right, top to bottom.
    var surfaces: [TerminalSurfaceView] {
        func collect(_ view: NSView) -> [TerminalSurfaceView] {
            if let surface = view as? TerminalSurfaceView { return [surface] }
            return view.subviews.flatMap(collect)
        }
        return collect(self)
    }

    func split(_ target: TerminalSurfaceView, adding surface: TerminalSurfaceView, direction: SplitDirection) {
        guard let parent = target.superview else { return }
        let split = PaneSplitView()
        split.isVertical = direction == .right || direction == .left
        replace(target, in: parent, with: split)
        let ordered = direction == .right || direction == .down ? [target, surface] : [surface, target]
        for view in ordered { split.addArrangedSubview(view) }
        split.layoutSubtreeIfNeeded()
        split.equalize()
    }

    /// Takes a surface out; its sibling grows into the space it leaves.
    func remove(_ surface: TerminalSurfaceView) {
        guard let split = surface.superview as? NSSplitView else { return }
        split.removeArrangedSubview(surface)
        surface.removeFromSuperview()
        guard split.arrangedSubviews.count == 1, let survivor = split.arrangedSubviews.first,
              let parent = split.superview
        else { return }
        split.removeArrangedSubview(survivor)
        survivor.removeFromSuperview()
        replace(split, in: parent, with: survivor)
    }

    /// The nearest surface in a direction from `surface`, or the previous or next in reading order.
    func neighbour(of surface: TerminalSurfaceView, toward target: SplitTarget) -> TerminalSurfaceView? {
        let all = surfaces
        guard all.count > 1, let index = all.firstIndex(of: surface) else { return nil }
        switch target {
        case .previous: return all[(index - 1 + all.count) % all.count]
        case .next: return all[(index + 1) % all.count]
        default: break
        }
        let from = convert(surface.bounds, from: surface)
        let candidates = all.filter { $0 !== surface }.compactMap { other -> (TerminalSurfaceView, CGFloat)? in
            let frame = convert(other.bounds, from: other)
            // NSView coordinates: y grows upwards.
            let inDirection = switch target {
            case .left: frame.maxX <= from.minX + 1
            case .right: frame.minX >= from.maxX - 1
            case .up: frame.minY >= from.maxY - 1
            case .down: frame.maxY <= from.minY + 1
            default: false
            }
            guard inDirection else { return nil }
            return (other, hypot(frame.midX - from.midX, frame.midY - from.midY))
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// Moves the nearest divider that runs across `direction` by `amount` points.
    func resize(_ surface: TerminalSurfaceView, toward direction: SplitTarget, by amount: CGFloat) {
        let vertical = direction == .left || direction == .right
        var child: NSView = surface
        while let split = child.superview as? NSSplitView {
            if split.isVertical == vertical, let index = split.arrangedSubviews.firstIndex(of: child) {
                // Prefer the divider after this pane; the last pane uses the one before it.
                let divider = index < split.arrangedSubviews.count - 1 ? index : index - 1
                let frame = split.arrangedSubviews[divider].frame
                let edge = vertical ? frame.maxX : frame.maxY
                let grows = direction == .right || direction == .up
                split.setPosition(edge + (grows == vertical ? amount : -amount), ofDividerAt: divider)
                return
            }
            child = split
        }
    }

    func equalize() {
        func walk(_ view: NSView) {
            (view as? PaneSplitView)?.equalize()
            view.subviews.forEach(walk)
        }
        walk(self)
    }

    private func replace(_ old: NSView, in parent: NSView, with new: NSView) {
        if let split = parent as? NSSplitView, let index = split.arrangedSubviews.firstIndex(of: old) {
            // Take over the old pane's space; NSSplitView keeps a new view's own size.
            new.frame = old.frame
            split.removeArrangedSubview(old)
            old.removeFromSuperview()
            split.insertArrangedSubview(new, at: index)
            split.adjustSubviews()
        } else {
            old.removeFromSuperview()
            place(new, in: parent)
        }
    }

    private func place(_ view: NSView, in parent: NSView) {
        view.frame = parent.bounds
        view.autoresizingMask = [.width, .height]
        parent.addSubview(view)
    }
}

final class PaneSplitView: NSSplitView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var dividerColor: NSColor { .separatorColor }

    func equalize() {
        let count = arrangedSubviews.count
        guard count > 1 else { return }
        let length = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(count - 1)
        for index in 0..<(count - 1) {
            setPosition(length / CGFloat(count) * CGFloat(index + 1) + dividerThickness * CGFloat(index), ofDividerAt: index)
        }
    }
}
