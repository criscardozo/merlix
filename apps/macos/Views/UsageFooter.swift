import SwiftUI

/// Whether Claude's usage sits at the top of the sidebar or pops up from the footer.
enum UsagePlacement {
    static let pinnedKey = "usagePinned"
}

/// The bottom of the sidebar, under a separator: Claude's plan usage on the
/// left (a ring with the 5-hour window; hovering shows the numbers, clicking
/// pins them to the top of the sidebar) and Settings on the right.
struct UsageFooter: View {
    @AppStorage(UsagePlacement.pinnedKey, store: .merlix) private var pinned = false
    @State private var hovering = false

    var body: some View {
        let usage = UsageMonitor.shared
        VStack(spacing: 0) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
            HStack(spacing: 8) {
                if usage.available, !pinned {
                    Button {
                        hovering = false
                        withAnimation(.smooth(duration: 0.2)) { pinned = true }
                    } label: {
                        HStack(spacing: 8) {
                            UsageRing(used: usage.fiveHours?.used)
                                .frame(width: 18, height: 18)
                            Text("Claude")
                                .foregroundStyle(hovering ? .primary : .secondary)
                        }
                        .opacity(usage.stale ? 0.5 : 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        withAnimation(.smooth(duration: 0.18)) { hovering = inside }
                    }
                    .help("Click to pin usage to the top of the sidebar")
                    .accessibilityLabel("Claude usage")
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .frame(height: 44)
        }
        .overlay(alignment: .bottomLeading) {
            if hovering, !pinned {
                UsageCard(usage: usage)
                    .padding(.leading, 10)
                    .padding(.bottom, 48)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(1)
    }
}

/// Claude's usage at the top of the sidebar, with a button to send it back to the footer.
struct PinnedUsage: View {
    @AppStorage(UsagePlacement.pinnedKey, store: .merlix) private var pinned = false

    var body: some View {
        let usage = UsageMonitor.shared
        if pinned, usage.available {
            UsageCard(usage: usage) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { pinned = false }
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show usage as a popup from the bottom of the sidebar")
                .accessibilityLabel("Unpin usage")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct UsageCard<Accessory: View>: View {
    let usage: UsageMonitor
    var fillsWidth = false
    let accessory: Accessory

    init(usage: UsageMonitor, @ViewBuilder accessory: () -> Accessory) {
        self.usage = usage
        self.fillsWidth = true
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                accessory
            }
            if usage.stale {
                Text("No fresh usage numbers")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                row("5 hours", usage.fiveHours, resets: { $0.formatted(date: .omitted, time: .shortened) })
                row("Week", usage.week, resets: { $0.formatted(.dateTime.weekday(.abbreviated)) })
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ label: String, _ window: UsageMonitor.Window?, resets: (Date) -> String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            if let window {
                let percent = Text("\(Int(window.used))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(UsageRing.color(for: window.used))
                Text("\(percent) · resets \(resets(window.resetsAt))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .gridColumnAlignment(.trailing)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .gridColumnAlignment(.trailing)
            }
        }
    }
}

/// The 5-hour window as an arc over a faint track.
struct UsageRing: View {
    let used: Double?

    static func color(for used: Double) -> Color {
        switch used {
        case 100...: .red
        case 80...: .orange
        default: .primary
        }
    }

    var body: some View {
        let style = StrokeStyle(lineWidth: 2.25, lineCap: .round)
        return ZStack {
            Circle().stroke(.quaternary, style: style)
            if let used {
                Circle()
                    .trim(from: 0, to: max(used, 2) / 100)
                    .stroke(Self.color(for: used), style: style)
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(1.125)
    }
}

extension UsageCard where Accessory == EmptyView {
    init(usage: UsageMonitor) {
        self.usage = usage
        self.accessory = EmptyView()
    }
}
