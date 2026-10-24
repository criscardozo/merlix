import SwiftUI

/// The bottom of the sidebar, under a separator: Claude's plan usage on the
/// left (a ring with the 5-hour window outside and the week inside; hovering
/// shows the numbers) and Settings on the right.
struct UsageFooter: View {
    @State private var hovering = false

    var body: some View {
        let usage = UsageMonitor.shared
        VStack(spacing: 0) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
            HStack(spacing: 8) {
                if usage.available {
                    HStack(spacing: 8) {
                        UsageRing(fiveHours: usage.fiveHours?.used, week: usage.week?.used)
                            .frame(width: 18, height: 18)
                        Text("Claude")
                            .foregroundStyle(hovering ? .primary : .secondary)
                    }
                    .opacity(usage.stale ? 0.5 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(.smooth(duration: 0.18)) { hovering = inside }
                    }
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
            if hovering {
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

private struct UsageCard: View {
    let usage: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude")
                .font(.system(size: 13, weight: .semibold))
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
        .fixedSize()
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

/// Two concentric arcs over faint tracks: 5 hours outside, the week inside.
struct UsageRing: View {
    let fiveHours: Double?
    let week: Double?

    static func color(for used: Double) -> Color {
        switch used {
        case 100...: .red
        case 80...: .orange
        default: .primary
        }
    }

    var body: some View {
        ZStack {
            arc(fiveHours, inset: 0)
            arc(week, inset: 4.5)
        }
    }

    private func arc(_ used: Double?, inset: CGFloat) -> some View {
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
        .padding(inset + 1.125)
    }
}
