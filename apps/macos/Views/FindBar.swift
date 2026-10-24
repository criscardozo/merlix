import SwiftUI

/// Find in the selected terminal, driven by libghostty's own search: ⌘F opens
/// it, Return and ⇧Return move between matches, Esc closes it.
struct FindBar: View {
    let session: Session
    @Bindable var search: SearchState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $search.needle)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { navigate("next") }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    navigate("previous")
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
            if let total = search.total, !search.needle.isEmpty {
                Text(search.selected.map { "\($0 + 1)/\(total)" } ?? "\(total)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Group {
                Button { navigate("previous") } label: { Image(systemName: "chevron.up") }
                    .help("Previous Match (⇧⌘G)")
                    .accessibilityLabel("Previous Match")
                Button { navigate("next") } label: { Image(systemName: "chevron.down") }
                    .help("Next Match (⌘G)")
                    .accessibilityLabel("Next Match")
                Button { close() } label: { Image(systemName: "xmark") }
                    .help("Close (Esc)")
                    .accessibilityLabel("Close Find")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
        .onChange(of: search.focusRequest) { focused = true }
        .task(id: search.needle) {
            // Short needles match almost everything; wait for more typing, as Ghostty does.
            if (1..<3).contains(search.needle.count) {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            session.activeSurface?.performBinding("search:\(search.needle)")
        }
    }

    private func navigate(_ direction: String) {
        session.activeSurface?.performBinding("navigate_search:\(direction)")
    }

    private func close() {
        session.activeSurface?.performBinding("end_search")
        session.search = nil
        if let view = session.activeSurface { view.window?.makeFirstResponder(view) }
    }
}
