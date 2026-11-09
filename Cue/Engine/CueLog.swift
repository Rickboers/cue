import Foundation

/// A small on-device diary of what the system did to us (audio interruptions, floating window
/// events, background frame rate), written to Documents/cue-log.txt so problems that only happen
/// over the Camera app can be looked at afterwards.
enum CueLog {
    private static let queue = DispatchQueue(label: "cue.log")
    private static let url: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("cue-log.txt")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            guard let url, let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                let size = (try? h.seekToEnd()) ?? 0
                if size > 400_000 {
                    // Keep it small: start over.
                    try? h.truncate(atOffset: 0)
                }
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
