import SwiftUI

extension View {
    /// The "Rename Script" box: tap a title, type, done.
    func renameAlert(isPresented: Binding<Bool>, current: String, onRename: @escaping (String) -> Void) -> some View {
        modifier(RenameAlert(isPresented: isPresented, current: current, onRename: onRename))
    }
}

private struct RenameAlert: ViewModifier {
    @Binding var isPresented: Bool
    let current: String
    let onRename: (String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Script", isPresented: $isPresented) {
                TextField("Title", text: $text)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Rename", action: commit)
            }
            .onChange(of: isPresented) { _, shown in
                if shown { text = current }
            }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onRename(t) }
    }
}
