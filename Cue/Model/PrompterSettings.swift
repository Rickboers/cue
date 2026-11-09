import CoreGraphics
import Foundation
import Observation

enum FollowMode: String, CaseIterable, Identifiable, Codable {
    case voice, tilt, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .voice: return "Voice"
        case .tilt: return "Tilt"
        case .auto: return "Constant"
        }
    }
}

enum PointsLayout: String, CaseIterable, Identifiable, Codable {
    case off, pinned, only
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Script"
        case .pinned: return "Script + Points"
        case .only: return "Points"
        }
    }
}

/// How you hold the phone while recording with the Camera app. The floating window is shaped
/// (and, for landscape, turned) to match, since the Camera app's screen itself never rotates.
enum WindowShape: String, CaseIterable, Identifiable, Codable {
    case upright, landscape
    var id: String { rawValue }
    var title: String {
        switch self {
        case .upright: return "Upright"
        case .landscape: return "Landscape"
        }
    }
    /// Width ÷ height of the text as you read it.
    var aspect: Double {
        switch self {
        // A wide, short strip: stretch it across the top, right under the front camera.
        // Full width across the top and roomy: about seven lines.
        case .upright: return 3.0 / 2.0
        // A column beside the camera when the phone is on its side.
        case .landscape: return 2.0 / 3.0
        }
    }
    /// Drawing width in points, about the window's real size, so the text size setting looks the same.
    var canvasWidth: CGFloat {
        switch self {
        case .upright: return 400
        case .landscape: return 260
        }
    }
}

/// App-wide preferences, persisted in UserDefaults.
@Observable
final class PrompterSettings {
    static let shared = PrompterSettings()

    var fontSize: Double { didSet { save("fontSize", fontSize) } }
    var readingLine: Double { didSet { save("readingLine2", readingLine) } }
    var shape: WindowShape { didSet { save("shape", shape.rawValue) } }
    var mode: FollowMode { didSet { save("mode", mode.rawValue) } }
    var autoSpeed: Double { didSet { save("autoSpeed", autoSpeed) } }
    var tiltSensitivity: Double { didSet { save("tiltSensitivity", tiltSensitivity) } }
    var tiltReversed: Bool { didSet { save("tiltReversed", tiltReversed) } }
    var tiltInVoice: Bool { didSet { save("tiltInVoice", tiltInVoice) } }
    var voiceCommands: Bool { didSet { save("voiceCommands", voiceCommands) } }
    var dimSpoken: Bool { didSet { save("dimSpoken", dimSpoken) } }
    var margin: Double { didSet { save("margin", margin) } }
    var lineSpacing: Double { didSet { save("lineSpacing", lineSpacing) } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        var size = d.object(forKey: "fontSize") as? Double ?? 22
        // The sizes went down a step; move the old ones along once.
        if !d.bool(forKey: "fontSizes3") {
            d.set(true, forKey: "fontSizes3")
            let old: [Double: Double] = [24: 20, 30: 22, 38: 28, 46: 36, 26: 22, 32: 28, 40: 36]
            if let f = old[size] { size = f; d.set(f, forKey: "fontSize") }
        }
        fontSize = size
        readingLine = d.object(forKey: "readingLine2") as? Double ?? 0
        shape = WindowShape(rawValue: d.string(forKey: "shape") ?? "") ?? .upright
        mode = FollowMode(rawValue: d.string(forKey: "mode") ?? "") ?? .voice
        autoSpeed = d.object(forKey: "autoSpeed") as? Double ?? 140
        tiltSensitivity = d.object(forKey: "tiltSensitivity") as? Double ?? 1
        tiltReversed = d.object(forKey: "tiltReversed") as? Bool ?? false
        tiltInVoice = d.object(forKey: "tiltInVoice") as? Bool ?? true
        voiceCommands = d.object(forKey: "voiceCommands") as? Bool ?? true
        dimSpoken = d.object(forKey: "dimSpoken") as? Bool ?? true
        margin = d.object(forKey: "margin") as? Double ?? 24
        lineSpacing = d.object(forKey: "lineSpacing") as? Double ?? 1.22
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }
}
