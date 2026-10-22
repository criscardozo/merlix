import SwiftUI

/// Asks for a group's name, with the field focused so typing starts at once.
struct NewGroupSheet: View {
    let create: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Group")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("Group name"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
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
