import SwiftUI

struct ScriptEditorView: View {
    let scriptID: UUID
    let onPrompt: (Script) -> Void

    @Environment(ScriptStore.self) private var store
    @State private var script = Script(title: "", body: "")
    @State private var loaded = false
    @State private var tab: Tab = .script
    @FocusState private var editing: Bool
    @State private var renaming = false

    enum Tab: String, CaseIterable, Identifiable {
        case script = "Script", points = "Talking Points"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)

            ZStack(alignment: .topLeading) {
                TextEditor(text: tab == .script ? $script.body : $script.points)
                    .font(.system(size: 19))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .focused($editing)
                    .padding(.horizontal, 12)

                if (tab == .script ? script.body : script.points).isEmpty {
                    Text(tab == .script
                         ? "Write or paste your script…"
                         : "One talking point per line.\nThey stay on screen while you talk.")
                        .font(.system(size: 19))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .renameAlert(isPresented: $renaming, current: script.title) { script.title = $0 }
        .toolbar {
            // Tap the title to rename the script.
            ToolbarItem(placement: .principal) {
                Button {
                    renaming = true
                } label: {
                    HStack(spacing: 5) {
                        Text(script.title.isEmpty ? "Untitled" : script.title)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(script.title.isEmpty ? .secondary : .primary)
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Rename")
            }
            if editing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { editing = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if !editing {
                    Button {
                        store.update(script)
                        onPrompt(script)
                    } label: {
                        Label("Start Prompter", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .foregroundStyle(.black)
                    .disabled(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && script.pointList.isEmpty)
                }
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .background(.bar.opacity(editing ? 1 : 0))
        }
        .onAppear {
            guard !loaded, let s = store.script(scriptID) else { return }
            script = s
            loaded = true
            if s.body.isEmpty { editing = true }
        }
        .onChange(of: script) { _, new in
            if loaded { store.update(new) }
        }
        .onDisappear {
            if script.body.isEmpty && script.points.isEmpty && script.title.isEmpty {
                store.delete([script.id])
            }
        }
    }

    private var footer: String {
        if tab == .points {
            let n = script.pointList.count
            return n == 1 ? "1 talking point" : "\(n) talking points"
        }
        return "\(script.wordCount.formatted()) words · about \(script.durationText)"
    }
}
