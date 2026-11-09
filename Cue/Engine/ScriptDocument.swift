import Foundation

/// A script parsed once into display words and match tokens.
/// Display words are what you see; tokens are what the voice follower compares against.
final class ScriptDocument {

    enum Break: UInt8, Comparable {
        case none, line, paragraph
        static func < (a: Break, b: Break) -> Bool { a.rawValue < b.rawValue }
    }

    struct Word {
        let text: String
        let breakBefore: Break
        /// Match tokens produced by this word (may be empty for pure punctuation like "—").
        let tokenRange: Range<Int>
    }

    let words: [Word]
    let tokens: [String]
    let phonetics: [String]
    /// How much a match on this token counts. Rare, long words are worth more than "the".
    let weights: [Float]
    let isStopword: [Bool]
    /// Display word that owns each token.
    let tokenToWord: [Int]
    /// Word indices where sentences / paragraphs begin (sorted).
    let sentenceStarts: [Int]
    let paragraphStarts: [Int]
    /// Token indices where sentences begin.
    let sentenceStartTokens: Set<Int>

    /// Trigram → token positions where the trigram starts. Used to re-find your place anywhere in a long script.
    private let trigramIndex: [Int: [Int32]]
    private let bigramIndex: [Int: [Int32]]

    var isEmpty: Bool { words.isEmpty }

    init(text: String) {
        var words: [Word] = []
        var tokens: [String] = []
        var tokenToWord: [Int] = []
        var sentenceStarts: [Int] = []
        var paragraphStarts: [Int] = []

        var pendingBreak: Break = .paragraph
        var newSentence = true
        var newlineRun = 0

        var current = ""
        func flushWord() {
            guard !current.isEmpty else { return }
            let toks = TextNormalizer.tokens(forWord: current)
            let start = tokens.count
            tokens.append(contentsOf: toks)
            let wi = words.count
            for _ in toks { tokenToWord.append(wi) }
            let brk: Break = words.isEmpty ? .none : pendingBreak
            if words.isEmpty || pendingBreak == .paragraph { paragraphStarts.append(wi) }
            if newSentence || pendingBreak != .none { sentenceStarts.append(wi) }
            words.append(Word(text: current, breakBefore: brk, tokenRange: start..<tokens.count))
            if let last = current.last(where: { !"\"'”’)]".contains($0) }), ".!?".contains(last) {
                newSentence = true
            } else {
                newSentence = false
            }
            pendingBreak = .none
            current = ""
        }

        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\u{2028}" || ch == "\u{2029}" {
                flushWord()
                newlineRun += 1
                pendingBreak = newlineRun >= 2 ? .paragraph : max(pendingBreak, .line)
            } else if ch.isWhitespace {
                flushWord()
            } else {
                if newlineRun > 0 { newlineRun = 0 }
                current.append(ch)
            }
        }
        flushWord()

        self.words = words
        self.tokens = tokens
        self.tokenToWord = tokenToWord
        self.sentenceStarts = sentenceStarts
        self.paragraphStarts = paragraphStarts
        self.phonetics = tokens.map(TextNormalizer.phonetic)
        self.sentenceStartTokens = Set(sentenceStarts.compactMap { w in
            words[w].tokenRange.isEmpty ? nil : words[w].tokenRange.lowerBound
        })

        var df: [String: Int] = [:]
        for t in tokens { df[t, default: 0] += 1 }
        let n = Float(max(tokens.count, 1))
        var weights: [Float] = []
        var stop: [Bool] = []
        weights.reserveCapacity(tokens.count)
        for t in tokens {
            let isStop = TextNormalizer.stopwords.contains(t)
            stop.append(isStop)
            if isStop || t.count <= 2 {
                weights.append(0.4)
            } else {
                // Inverse document frequency, softened. Unique words → 1.0, very common words → ~0.6.
                let freq = Float(df[t] ?? 1) / n
                let idf = min(1, max(0, -log10(freq) / 3))
                weights.append(0.6 + 0.4 * idf)
            }
        }
        self.weights = weights
        self.isStopword = stop

        var tri: [Int: [Int32]] = [:]
        var bi: [Int: [Int32]] = [:]
        if tokens.count >= 2 {
            for i in 0..<(tokens.count - 1) {
                bi[Self.gramKey(tokens[i], tokens[i + 1]), default: []].append(Int32(i))
                if i + 2 < tokens.count {
                    tri[Self.gramKey(tokens[i], tokens[i + 1], tokens[i + 2]), default: []].append(Int32(i))
                }
            }
        }
        self.trigramIndex = tri
        self.bigramIndex = bi
    }

    static func gramKey(_ a: String, _ b: String, _ c: String = "") -> Int {
        var h = Hasher()
        h.combine(a); h.combine(b); h.combine(c)
        return h.finalize()
    }

    /// Token positions where the spoken phrase plausibly occurs anywhere in the script.
    func candidates(for spoken: [String], limit: Int = 40) -> [Int] {
        var votes: [Int: Int] = [:]
        if spoken.count >= 3 {
            for i in 0..<(spoken.count - 2) {
                let key = Self.gramKey(spoken[i], spoken[i + 1], spoken[i + 2])
                guard let hits = trigramIndex[key], hits.count < 200 else { continue }
                for h in hits { votes[Int(h) - i, default: 0] += 3 }
            }
        }
        if spoken.count >= 2 {
            for i in 0..<(spoken.count - 1) {
                // Skip bigrams made only of stopwords; they are everywhere.
                if TextNormalizer.stopwords.contains(spoken[i]) && TextNormalizer.stopwords.contains(spoken[i + 1]) { continue }
                let key = Self.gramKey(spoken[i], spoken[i + 1])
                guard let hits = bigramIndex[key], hits.count < 200 else { continue }
                for h in hits { votes[Int(h) - i, default: 0] += 1 }
            }
        }
        return votes
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { max(0, $0.key) }
    }

    // MARK: - Navigation helpers (word indices)

    func wordIndex(forToken t: Int) -> Int {
        if tokens.isEmpty { return 0 }
        if t >= tokenToWord.count { return words.count }
        return tokenToWord[max(0, t)]
    }

    func tokenIndex(forWord w: Int) -> Int {
        if w >= words.count { return tokens.count }
        // Words without tokens (e.g. "—") map to the next word that has one.
        var i = max(0, w)
        while i < words.count {
            if !words[i].tokenRange.isEmpty { return words[i].tokenRange.lowerBound }
            i += 1
        }
        return tokens.count
    }

    /// Start of the sentence containing word `w`.
    func sentenceStart(containing w: Int) -> Int {
        lastStart(in: sentenceStarts, atOrBefore: w)
    }

    func previousSentenceStart(before w: Int) -> Int {
        lastStart(in: sentenceStarts, atOrBefore: w - 1)
    }

    func nextSentenceStart(after w: Int) -> Int {
        firstStart(in: sentenceStarts, after: w) ?? words.count
    }

    func nextParagraphStart(after w: Int) -> Int {
        firstStart(in: paragraphStarts, after: w) ?? words.count
    }

    private func lastStart(in arr: [Int], atOrBefore w: Int) -> Int {
        var lo = 0, hi = arr.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if arr[mid] <= w { best = arr[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    private func firstStart(in arr: [Int], after w: Int) -> Int? {
        var lo = 0, hi = arr.count - 1
        var best: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if arr[mid] > w { best = arr[mid]; hi = mid - 1 } else { lo = mid + 1 }
        }
        return best
    }

    /// Rare words, for the recognizer's vocabulary hints.
    /// The words and short phrases just ahead of word `w`, as hints for the recognizer: knowing what
    /// you're about to say, it picks the script's word when your accent leaves it unsure.
    func upcomingContext(from w: Int, words count: Int = 50) -> [String] {
        let lo = max(0, w - 4), hi = min(words.count, w + count)
        guard lo < hi else { return [] }
        func clean(_ w: Word) -> String { w.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
        var out: [String] = [], seen = Set<String>()
        for i in lo..<hi {
            let c = clean(words[i])
            let r = words[i].tokenRange
            guard c.count >= 3, r.count == 1, !isStopword[r.lowerBound] else { continue }
            if seen.insert(c.lowercased()).inserted { out.append(c) }
        }
        // Three-word phrases carry the most weight ("catches it up"), every other word.
        var i = lo
        while i + 3 <= hi {
            out.append((i..<i + 3).map { clean(words[$0]) }.joined(separator: " "))
            i += 2
        }
        return out
    }

    func distinctiveWords(limit: Int) -> [String] {
        var seen = Set<String>()
        let sentenceSet = Set(sentenceStarts)
        func clean(_ w: Word) -> String { w.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
        // Capitalised mid-sentence words are usually names — the ones recognizers miss most —
        // and they count as names everywhere, even at the start of a sentence. Short ones too ("Cue", "AI").
        var names = Set<String>()
        for (i, w) in words.enumerated() where !sentenceSet.contains(i) {
            let c = clean(w)
            if c.count >= 2, c.first!.isUppercase, c.allSatisfy(\.isLetter) { names.insert(c.lowercased()) }
        }
        var out: [(String, Float)] = []
        for w in words {
            let r = w.tokenRange
            guard r.count == 1, !isStopword[r.lowerBound] else { continue }
            let c = clean(w)
            let key = c.lowercased()
            let isName = names.contains(key)
            guard c.count >= (isName ? 2 : 4), c.allSatisfy({ $0.isLetter || $0 == "'" }) else { continue }
            if seen.insert(key).inserted {
                out.append((c, weights[r.lowerBound] + (isName ? 1 : 0)))
            }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The script's sentences as plain text (used to train the custom recognizer model).
    func sentences(limit: Int) -> [String] {
        var out: [String] = []
        let starts = sentenceStarts + [words.count]
        for k in 0..<(starts.count - 1) where out.count < limit {
            let s = words[starts[k]..<starts[k + 1]].map(\.text).joined(separator: " ")
            if !s.isEmpty { out.append(s) }
        }
        return out
    }
}
