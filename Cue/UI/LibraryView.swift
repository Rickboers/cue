import SwiftUI

struct LibraryView: View {
    @Environment(ScriptStore.self) private var store
    @State private var path: [UUID] = []
    @State private var prompting: Script?
    @State private var showSettings = false
    @State private var renamingID: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.sorted) { script in
                    NavigationLink(value: script.id) {
                        HStack(spacing: 12) {
                            ScriptRow(script: script)
                            Spacer(minLength: 0)
                            Button {
                                prompting = script
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 44, height: 44)
                                    .background(Color.cueAccent, in: Circle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Start prompter")
                        }
                    }
                    .contextMenu {
                        Button {
                            renamingID = script.id
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            prompting = script
                        } label: {
                            Label("Prompt", systemImage: "play.fill")
                        }
                        .tint(.cueAccent)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.sorted[$0].id }
                    store.delete(ids)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Scripts")
            .overlay {
                if store.scripts.isEmpty {
                    ContentUnavailableView {
                        Label("No Scripts", systemImage: "text.alignleft")
                    } description: {
                        Text("Tap Paste or New below to add a script.")
                    }
                }
            }
            // Thumb order, like the prompter: Settings far left, the everyday action far right.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 50, height: 50)
                            .background(.regularMaterial, in: Circle())
                    }
                    .accessibilityLabel("Settings")

                    Spacer()

                    Button {
                        path.append(store.create().id)
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 18)
                            .frame(height: 50)
                            .background(.regularMaterial, in: Capsule())
                    }

                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.joined(separator: "\n\n")
                        Task { @MainActor in
                            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            prompting = store.create(body: text)
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.extraLarge)
                    .labelStyle(.titleAndIcon)
                    .tint(.cueAccent)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .navigationDestination(for: UUID.self) { id in
                ScriptEditorView(scriptID: id) { script in
                    prompting = script
                }
            }
        }
        .fullScreenCover(item: $prompting) { script in
            PrompterView(script: script)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .renameAlert(isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } }),
                     current: renamingID.flatMap { store.script($0)?.title } ?? "") { title in
            if let id = renamingID, var s = store.script(id) {
                s.title = title
                store.update(s)
            }
        }
        #if DEBUG
        .onAppear {
            // Screenshot hook: `-demoPrompter` opens the first script's prompter.
            if CommandLine.arguments.contains("-demoPrompter"), prompting == nil {
                prompting = store.sorted.first
            }
        }
        #endif
    }
}

private struct ScriptRow: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(script.displayTitle)
                .font(.headline)
                .lineLimit(1)
            if !script.preview.isEmpty {
                Text(script.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("\(script.wordCount.formatted()) words · \(script.durationText)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
