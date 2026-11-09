#if DEBUG
import UIKit

/// Development aid: launched with `-snapshot`, the app saves a picture of its own screen to
/// Documents/snapshot.png every two seconds, so the layout can be checked on a real iPhone.
enum DebugSnapshot {
    private static var timer: Timer?

    static func startIfRequested() {
        guard CommandLine.arguments.contains("-snapshot"), timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in capture() }
    }

    private static func capture() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        try? image.pngData()?.write(to: dir.appendingPathComponent("snapshot.png"), options: .atomic)
    }
}
#endif
