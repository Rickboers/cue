import Foundation

enum VoiceCommand: Equatable {
    case top
    case backLines(Int)
    case backSentence
    case skipLines(Int)
    case nextSentence
    case skipParagraph
    case nextPoint
    case previousPoint
    case pause
    case resume

    var label: String {
        switch self {
        case .top: return "Back to top"
        case .backLines(let n): return n == 1 ? "Back a line" : "Back \(n) lines"
        case .backSentence: return "Back a sentence"
        case .skipLines(let n): return n == 1 ? "Skip a line" : "Skip \(n) lines"
        case .nextSentence: return "Next sentence"
        case .skipParagraph: return "Skip ahead"
        case .nextPoint: return "Next point"
        case .previousPoint: return "Previous point"
        case .pause: return "Paused"
        case .resume: return "Resumed"
        }
    }
}

/// Spotting spoken commands inside the live transcript.
enum VoiceCommands {

    struct Match {
        let command: VoiceCommand
        /// Hypothesis index right after the command.
        let end: Int
        let phrase: [String]
        /// A longer command starts with this one ("go back" vs "go back two lines"); worth waiting a beat.
        let mightGrow: Bool
    }

    private static let numbers: [String: Int] = [
        "a": 1, "one": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4, "for": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple": 2, "few": 3,
    ]

    private static let patterns: [(String, VoiceCommand)] = [
        ("back to the top", .top), ("back to top", .top), ("go to the top", .top), ("from the top", .top),
        ("start over", .top), ("start from the beginning", .top), ("back to the beginning", .top),
        ("go to the beginning", .top), ("back to the start", .top), ("restart the script", .top),
        ("top of the script", .top),

        ("go back", .backSentence), ("back a bit", .backSentence), ("back a sentence", .backSentence),
        ("previous sentence", .backSentence), ("try that again", .backSentence),
        ("take that again", .backSentence), ("one more time", .backSentence),

        ("previous line", .backLines(1)), ("up a line", .backLines(1)),

        ("skip ahead", .skipParagraph), ("skip forward", .skipParagraph), ("skip a bit", .skipParagraph),
        ("skip this part", .skipParagraph), ("next paragraph", .skipParagraph), ("skip this", .skipParagraph),

        ("next sentence", .nextSentence), ("skip a sentence", .nextSentence),
        ("next line", .skipLines(1)), ("down a line", .skipLines(1)),

        ("next point", .nextPoint), ("next topic", .nextPoint),
        ("previous point", .previousPoint), ("last point", .previousPoint), ("back a point", .previousPoint),

        ("pause prompter", .pause), ("pause the prompter", .pause), ("stop scrolling", .pause),
        ("resume prompter", .resume), ("start scrolling", .resume), ("keep scrolling", .resume),
    ]

    /// Longest first, so "go back to the top" wins over "go back".
    private static let tokenPatterns: [([String], VoiceCommand)] = patterns
        .map { (TextNormalizer.tokens($0.0), $0.1) }
        .sorted { $0.0.count > $1.0.count }

    /// Finds the command in the hypothesis after `start`. When phrases overlap ("go back to the top"
    /// contains "go back"), the one reaching furthest wins, then the longest.
    static func find(in hyp: [String], from start: Int) -> Match? {
        guard hyp.count > start else { return nil }
        var best: Match? = nil
        func consider(_ m: Match) {
            if let b = best, (b.end, b.phrase.count) >= (m.end, m.phrase.count) { return }
            best = m
        }
        for i in start..<hyp.count {
            // "back N lines" / "skip N lines" / "up N lines" / "go back N lines"
            if let m = numberedLines(hyp, at: i) { consider(m) }
            for (pat, cmd) in tokenPatterns where i + pat.count <= hyp.count {
                guard Array(hyp[i..<(i + pat.count)]) == pat else { continue }
                let end = i + pat.count
                let grow = end == hyp.count && (pat.last == "back" || tokenPatterns.contains { other in
                    other.0.count > pat.count && Array(other.0.prefix(pat.count)) == pat
                })
                consider(Match(command: cmd, end: end, phrase: pat, mightGrow: grow))
            }
        }
        return best
    }

    private static func numberedLines(_ hyp: [String], at i: Int) -> Match? {
        var k = i
        guard k < hyp.count else { return nil }
        if hyp[k] == "go" { k += 1 }
        guard k + 2 < hyp.count else { return nil }
        let verb = hyp[k]
        let backward: Bool
        switch verb {
        case "back", "up": backward = true
        case "skip", "down", "forward": backward = false
        default: return nil
        }
        guard let n = numbers[hyp[k + 1]] else { return nil }
        let unit = hyp[k + 2]
        guard unit == "line" || unit == "lines" else { return nil }
        let end = k + 3
        return Match(command: backward ? .backLines(n) : .skipLines(n), end: end,
                     phrase: Array(hyp[i..<end]), mightGrow: false)
    }

    /// True if the phrase is actually part of the script near `token` (then it's reading, not a command).
    static func phrase(_ phrase: [String], appearsIn doc: ScriptDocument, near token: Int) -> Bool {
        guard !phrase.isEmpty else { return false }
        let lo = max(0, token - 20)
        let hi = min(doc.tokens.count, token + 40)
        guard hi - lo >= phrase.count else { return false }
        var j = lo
        while j + phrase.count <= hi {
            if Array(doc.tokens[j..<(j + phrase.count)]) == phrase { return true }
            j += 1
        }
        return false
    }
}
