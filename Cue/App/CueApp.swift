import SwiftUI

@main
struct CueApp: App {
    @State private var store = ScriptStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .environment(PrompterSettings.shared)
                .tint(.cueAccent)
                #if DEBUG
                .onAppear { DebugSnapshot.startIfRequested() }
                #endif
        }
        .onChange(of: phase) { _, newPhase in
            CueLog.write("app \(newPhase == .active ? "active" : newPhase == .background ? "background" : "inactive")")
            if newPhase != .active { store.saveNow() }
        }
    }
}

extension Color {
    static let cueAccent = Color(red: 1, green: 0.78, blue: 0.16)
}
