import SwiftUI

/// Asks for a name, with the field focused so typing starts at once.
struct NameSheet: View {
    let title: String
    var placeholder = "Name"
    var confirm = "Create"
    let create: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $name, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .defaultFocus($focused, true)
        // The sheet is not key yet when it appears; focus once it is.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        create(trimmed)
        dismiss()
    }
}

/// Asks for a new group's name.
struct NewGroupSheet: View {
    let create: (String) -> Void

    var body: some View {
        NameSheet(title: "New Group", placeholder: "Group name", create: create)
    }
}
