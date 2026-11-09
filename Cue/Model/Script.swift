import Foundation
import Observation

struct Script: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    /// One talking point per line.
    var points: String = ""
    var pointsLayout: PointsLayout = .off
    var updated = Date()

    var pointList: [String] {
        points
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line in
                var l = Substring(line)
                while let f = l.first, "-•*–—·".contains(f) { l = l.dropFirst() }
                return l.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    var wordCount: Int {
        var n = 0
        var inWord = false
        for c in body.unicodeScalars {
            let ws = CharacterSet.whitespacesAndNewlines.contains(c)
            if !ws && !inWord { n += 1 }
            inWord = !ws
        }
        return n
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "New Script" : String(trimmed.prefix(48))
    }

    var preview: String {
        String(body.prefix(160)).replacingOccurrences(of: "\n", with: " ")
    }

    /// Spoken length at a typical 150 words per minute.
    var durationText: String {
        let seconds = Int((Double(wordCount) / 150 * 60).rounded())
        if seconds < 60 { return "\(seconds) sec" }
        let m = seconds / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(m % 60) min"
    }
}

/// All scripts, saved as one JSON file in Documents. Saves are debounced so long scripts stay snappy.
@Observable
final class ScriptStore {
    private(set) var scripts: [Script] = []

    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("scripts.json")
    }()

    init() {
        load()
    }

    var sorted: [Script] { scripts.sorted { $0.updated > $1.updated } }

    func script(_ id: UUID) -> Script? { scripts.first { $0.id == id } }

    @discardableResult
    func create(body: String = "", title: String = "") -> Script {
        let s = Script(title: title, body: body)
        scripts.append(s)
        scheduleSave()
        return s
    }

    func update(_ script: Script) {
        guard let i = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        var s = script
        s.updated = Date()
        scripts[i] = s
        scheduleSave()
    }

    func delete(_ ids: [UUID]) {
        scripts.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func saveNow() {
        saveWork?.cancel()
        write(scripts)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = scripts
        let work = DispatchWorkItem { [weak self] in self?.write(snapshot) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func write(_ scripts: [Script]) {
        let url = self.url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(scripts) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = decoded
        } else {
            scripts = [Script.welcome]
            scheduleSave()
        }
    }
}

extension Script {
    static let welcome = Script(
        title: "Welcome to Cue",
        body: """
        Hi! This is Cue, a teleprompter that floats over your camera and follows your voice.

        Just start talking. As you read, the words you have said fade and the next line stays right where your eyes are. Skip a sentence and it catches up. Stumble and start the sentence again, and it goes back with you.

        You can steer it with your voice. Say go back to repeat a sentence. Say back two lines, or skip ahead to jump to the next paragraph. Say back to the top to start over.

        Tilt mode scrolls when you tilt your phone. Tip the top away from you to move forward and toward you to go back. Auto mode just scrolls at a steady pace.

        Tap Float Over Camera, open the Camera app, and hit record. Cue stays on top. Good luck with the video!
        """,
        points: """
        Say hi and introduce the app
        It follows your voice
        Voice commands: go back, skip ahead, back to the top
        Tilt and Auto modes
        Float over the Camera app
        """
    )
}
