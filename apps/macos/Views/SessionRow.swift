import SwiftUI

struct SessionRow: View {
    let session: Session
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(session.displayName)
                .fontWeight(session.unread ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            StatusIcon(status: session.status, unread: session.unread)
                .frame(width: 15, height: 15)
        }
        .font(.system(size: 13))
        .opacity(session.isRunning || selected ? 1 : 0.55)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(selected ? 0.1 : hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Working, done (filled while unseen) or needs you; nothing while idle.
struct StatusIcon: View {
    let status: SessionStatus
    let unread: Bool

    var body: some View {
        switch status {
        case .working:
            Spinner()
        case .needsYou:
            ZStack {
                Circle().strokeBorder(.orange, lineWidth: 1.75)
                Circle().fill(.orange).padding(4)
            }
        case .done where unread:
            ZStack {
                Circle().fill(.primary)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        case .idle:
            Color.clear
        }
    }
}

/// An open arc that spins, like the activity ring in the sidebar mockups.
struct Spinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.82)
            .stroke(.primary, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .padding(1)
            .onAppear { spinning = true }
    }
}
