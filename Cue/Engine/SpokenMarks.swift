import CoreGraphics
import Foundation

/// When each word turned "said", so it can fade from bright to dim instead of snapping.
///
/// In Voice mode only words the recognizer actually heard are marked; words you skipped or swapped
/// stay bright until you move on to the next line. Tilt, Constant and dragging mark everything passed.
final class SpokenMarks {
    static let fadeDuration: Double = 0.4

    private var at: [Double]      // -1 = not said
    private var high = 0          // nothing is marked at or after this index
    private var filled = 0        // everything before this index is marked
    private(set) var lastChange: Double = -1

    init(count: Int) {
        at = Array(repeating: -1, count: count)
    }

    func mark(_ w: Int, now: Double) {
        guard w >= 0, w < at.count, at[w] < 0 else { return }
        at[w] = now
        high = max(high, w + 1)
        lastChange = now
    }

    /// Mark every word before `end` (words passed by scrolling, or left behind on earlier lines).
    func fill(upTo end: Int, now: Double) {
        let e = min(end, at.count)
        guard filled < e else { return }
        for w in filled..<e where at[w] < 0 {
            at[w] = now
            lastChange = now
        }
        filled = e
        high = max(high, e)
    }

    /// Going back: everything from `start` on is unsaid again.
    func clear(from start: Int) {
        let s = max(0, start)
        if s < high {
            for w in s..<high where at[w] >= 0 { at[w] = -1 }
            high = s
        }
        filled = min(filled, s)
    }

    func isFading(now: Double) -> Bool { now - lastChange < Self.fadeDuration }

    /// 0 = upcoming, 1 = fully said. Eases out so the change starts quick and settles softly.
    func amount(_ w: Int, now: Double) -> CGFloat {
        guard w >= 0, w < at.count, at[w] >= 0 else { return 0 }
        let t = (now - at[w]) / Self.fadeDuration
        if t >= 1 { return 1 }
        let u = 1 - max(0, t)
        return CGFloat(1 - u * u * u)
    }
}
