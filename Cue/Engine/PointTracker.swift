import Foundation

/// Talking points are ad-libbed, so there's no exact text to follow.
/// Instead we listen for each point's keywords and light up the point you're talking about.
final class PointTracker {

    let points: [String]
    private let keywords: [[(text: String, phonetic: String)]]
    private(set) var current = 0
    private var hypBase = 0

    init(points: [String]) {
        self.points = points
        self.keywords = points.map { point in
            var seen = Set<String>()
            return TextNormalizer.tokens(point)
                .filter { $0.count >= 3 && !TextNormalizer.stopwords.contains($0) && seen.insert($0).inserted }
                .map { ($0, TextNormalizer.phonetic($0)) }
        }
    }

    func set(_ index: Int, hypothesisCount: Int) {
        guard !points.isEmpty else { return }
        current = min(max(0, index), points.count - 1)
        hypBase = hypothesisCount
    }

    func newUtterance() { hypBase = 0 }

    /// Returns true if the highlighted point changed.
    @discardableResult
    func update(hypothesis: [String]) -> Bool {
        guard points.count > 1, hypothesis.count > hypBase else { return false }
        let tail = hypothesis[hypBase...].suffix(14)
        let spoken = tail.map { ($0, TextNormalizer.phonetic($0)) }

        var bestIndex = current
        var bestHits = 0
        for (k, kws) in keywords.enumerated() where k != current && !kws.isEmpty {
            var hits = 0
            var longHit = false
            for kw in kws where spoken.contains(where: { $0.0 == kw.text || ($0.1 == kw.phonetic && kw.phonetic.count >= 3) }) {
                hits += 1
                if kw.text.count >= 6 { longHit = true }
            }
            // The next point is the likely one; anything else needs stronger evidence.
            let needed = k == current + 1 ? (kws.count <= 2 && longHit ? 1 : 2) : 3
            if hits >= needed && hits > bestHits {
                bestHits = hits
                bestIndex = k
            }
        }
        guard bestIndex != current else { return false }
        current = bestIndex
        hypBase = hypothesis.count
        return true
    }
}
