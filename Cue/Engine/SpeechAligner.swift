import Foundation

/// Keeps track of where you are in the script from what the recognizer hears.
///
/// Each time the recognizer revises its hypothesis we take the last few spoken tokens and run a
/// weighted local alignment (Smith–Waterman) against the script around the current place. Matches
/// can be exact, sound-alike or near-spellings; rare words count more than "the"; skipped script
/// words, ad-libbed words and misheard words cost a little but don't break the match. The best
/// alignment ending on the latest spoken words tells us the next word to read.
///
/// Moving forward a little needs little evidence, big jumps and going backwards (restarting a
/// sentence) need more, and if nothing matches for a while we search the whole script.
final class SpeechAligner {

    struct Tuning {
        var tailLength = 10
        var behind = 45
        var ahead = 90
        var mismatch: Float = -0.4
        var gapSpoken: Float = 0.4
        var gapScript: Float = 0.3
        var gapScriptStopword: Float = 0.12
        var lostAfterTokens = 7
    }

    let doc: ScriptDocument
    var tuning = Tuning()

    /// Index of the next token to read.
    private(set) var position: Int = 0
    /// Hypothesis tokens before this index are ignored (consumed by a command or a manual move).
    private var hypBase = 0
    /// Hypothesis length (after base) at the last accepted match.
    private var lastMatchCount = 0
    private(set) var lastScore: Float = 0
    /// Script tokens the last accepted update actually heard (matched), oldest first. Skipped or
    /// misheard script words are not in here, so they aren't shown as said.
    private(set) var heardTokens: [Int] = []
    /// A jump backed by a single word waits for the next hypothesis to agree, so one misheard
    /// (or still-changing) word can't send us ahead.
    private var pendingJump: Int?

    init(doc: ScriptDocument) {
        self.doc = doc
    }

    var wordPosition: Int { doc.wordIndex(forToken: position) }

    /// Jump somewhere by hand (tilt, drag, command). Old speech must not pull us back.
    func move(toToken t: Int, hypothesisCount: Int) {
        position = min(max(0, t), doc.tokens.count)
        hypBase = hypothesisCount
        lastMatchCount = 0
        pendingJump = nil
    }

    /// The recognizer started a fresh task: hypotheses restart from zero.
    func newUtterance() {
        hypBase = 0
        lastMatchCount = 0
        pendingJump = nil
    }

    /// Feed the recognizer's full current hypothesis. Returns true when the place changed.
    @discardableResult
    func update(hypothesis: [String]) -> Bool {
        guard !doc.tokens.isEmpty, hypothesis.count > hypBase else { return false }
        let usable = hypothesis[hypBase...].filter { !TextNormalizer.fillers.contains($0) }
        guard !usable.isEmpty else { return false }
        let tail = Array(usable.suffix(tuning.tailLength))
        let spoken = tail.map { SpokenToken(text: $0, phonetic: TextNormalizer.phonetic($0)) }

        let lo = max(0, position - tuning.behind)
        let hi = min(doc.tokens.count, position + tuning.ahead)
        let local = align(spoken, lo: lo, hi: hi, strict: false)
        var best = local.normal
        if let single = local.single, single.adjusted > (best?.adjusted ?? -.infinity) {
            if pendingJump == single.next {
                best = single
            } else {
                pendingJump = single.next
            }
        } else {
            pendingJump = nil
        }

        // Lost: a run of speech without a match. Look everywhere (long scripts, big skips).
        if best == nil, usable.count - lastMatchCount >= tuning.lostAfterTokens, tail.count >= 4 {
            for c in doc.candidates(for: tail) {
                let clo = max(0, c - 4)
                let chi = min(doc.tokens.count, c + tail.count + 12)
                if clo >= lo && chi <= hi { continue } // already searched
                if let r = align(spoken, lo: clo, hi: chi, strict: true).normal,
                   r.adjusted > (best?.adjusted ?? -.infinity) {
                    best = r
                }
            }
        }

        guard let found = best else { return false }
        if found.single { pendingJump = nil }
        lastMatchCount = usable.count
        lastScore = found.score
        let delta = found.next - position
        // Tiny backward wobbles come from the recognizer revising its last word. Ignore them.
        if delta < 0 && delta >= -2 { return false }
        if delta == 0 { return false }
        position = found.next
        heardTokens = found.heard
        return true
    }

    // MARK: - Alignment

    private struct SpokenToken {
        let text: String
        let phonetic: String
    }

    private struct Candidate {
        let next: Int
        let score: Float
        let matches: Int
        let recent: Float
        let adjusted: Float
        var single = false
        var heard: [Int] = []
        var cell = 0
    }

    private enum Step: UInt8 {
        case start, match, mismatch, extraSpoken, skippedScript
        case mergedSpoken   // two heard words → one script word
        case mergedScript   // one heard word → two script words
        var isMatch: Bool { self == .match || self == .mergedSpoken || self == .mergedScript }
    }

    /// How alike two words are, by spelling and by sound. 0 = different.
    private static func alike(_ a: String, _ ap: String, _ b: String, _ bp: String) -> Float {
        if a == b { return 1 }
        if ap.count >= 2 && ap == bp { return a.first == b.first ? 0.85 : 0.75 }
        if a.count >= 4 && b.count >= 4 && TextNormalizer.editSimilarity(a, b) >= 0.75 { return 0.7 }
        // Close in sound though spelled differently: "anthropic" / "entropic", accents, mumbles.
        if ap.count >= 4 && bp.count >= 4 && TextNormalizer.editSimilarity(ap, bp) >= 0.75 { return 0.6 }
        return 0
    }

    private func similarity(_ s: SpokenToken, _ j: Int, isLast: Bool) -> Float {
        let t = doc.tokens[j]
        let base = Self.alike(s.text, s.phonetic, t, doc.phonetics[j])
        if base > 0 { return base }
        // One-sound words: "Cue" comes back as "queue", "Q" or "kew".
        if s.phonetic.count == 1 && s.phonetic == doc.phonetics[j] && t.count >= 2
            && !doc.isStopword[j] && !TextNormalizer.stopwords.contains(s.text) {
            return 0.6
        }
        // The word currently being spoken is often cut off in a partial result.
        if isLast && s.text.count >= 3 && t.hasPrefix(s.text) { return 0.6 }
        // Plural / tense slips: "line" vs "lines", "talk" vs "talked".
        if s.text.count >= 3 && t.count >= 3 && (t.hasPrefix(s.text) || s.text.hasPrefix(t)) && abs(t.count - s.text.count) <= 2 {
            return 0.65
        }
        return 0
    }

    /// Two heard words that make one script word: "tele prompter" → "teleprompter".
    private func mergedSpokenSimilarity(_ merged: SpokenToken, _ j: Int) -> Float {
        let t = doc.tokens[j]
        guard t.count >= 5, abs(merged.text.count - t.count) <= 3, merged.text.first == t.first else { return 0 }
        return Self.alike(merged.text, merged.phonetic, t, doc.phonetics[j])
    }

    /// One heard word that covers two script words: "subagents" → "sub agents", "github" → "git hub".
    private func mergedScriptSimilarity(_ s: SpokenToken, _ j: Int) -> Float {
        let a = doc.tokens[j - 1], b = doc.tokens[j]
        // Both must be real words: sound keys drop vowels, so "hooks" + "are" would pass for "hooks".
        guard s.text.count >= 5, s.text.first == a.first, b.count >= 2,
              !doc.isStopword[j - 1], !doc.isStopword[j],
              abs(s.text.count - (a.count + b.count)) <= 2 else { return 0 }
        let merged = a + b
        if s.text == merged { return 1 }
        return TextNormalizer.editSimilarity(s.text, merged) >= 0.8 ? 0.7 : 0
    }

    private func align(_ spoken: [SpokenToken], lo: Int, hi: Int, strict: Bool) -> (normal: Candidate?, single: Candidate?) {
        let m = spoken.count
        let L = hi - lo
        guard m > 0, L > 0 else { return (nil, nil) }
        let w = L + 1
        var H = [Float](repeating: 0, count: (m + 1) * w)
        var M = [Int16](repeating: 0, count: (m + 1) * w)
        // Match score earned by the newest few spoken words along the path: the evidence for moving now.
        var R = [Float](repeating: 0, count: (m + 1) * w)
        // Script token where the path's first match sits (−1 = none yet).
        var S = [Int32](repeating: -1, count: (m + 1) * w)
        // How each cell was reached, to trace back which script words were really heard.
        var O = [Step](repeating: .start, count: (m + 1) * w)
        // Words heard since the path last skipped script words (P), and how many it skipped (K).
        // "Skipped five words, then heard one" is a guess until another word backs it up.
        var P = [Int16](repeating: 0, count: (m + 1) * w)
        var K = [Int16](repeating: 0, count: (m + 1) * w)
        let recentFrom = m - 3
        let tn = tuning
        // Each heard word glued to the one before it, for split-word matches.
        let merged: [SpokenToken?] = (0..<m).map { k in
            guard k >= 1 else { return nil }
            let text = spoken[k - 1].text + spoken[k].text
            return SpokenToken(text: text, phonetic: TextNormalizer.phonetic(text))
        }

        for i in 1...m {
            let s = spoken[i - 1]
            let isLast = i == m
            let row = i * w, prev = (i - 1) * w
            for j in 1...L {
                let ti = lo + j - 1
                let sim = similarity(s, ti, isLast: isLast)
                let diagScore = sim > 0 ? sim * doc.weights[ti] : tn.mismatch
                let diag = H[prev + j - 1] + diagScore
                let up = H[prev + j] - tn.gapSpoken
                let left = H[row + j - 1] - (doc.isStopword[ti] ? tn.gapScriptStopword : tn.gapScript)
                var best: Float = 0
                var matches: Int16 = 0
                var recent: Float = 0
                var start: Int32 = -1
                var op = Step.start
                if diag > best {
                    best = diag
                    matches = M[prev + j - 1] + (sim > 0 ? 1 : 0)
                    recent = R[prev + j - 1] + (sim > 0 && i > recentFrom ? diagScore : 0)
                    start = S[prev + j - 1] >= 0 ? S[prev + j - 1] : (sim > 0 ? Int32(ti) : -1)
                    op = sim > 0 ? .match : .mismatch
                }
                if up > best { best = up; matches = M[prev + j]; recent = R[prev + j]; start = S[prev + j]; op = .extraSpoken }
                if left > best { best = left; matches = M[row + j - 1]; recent = R[row + j - 1]; start = S[row + j - 1]; op = .skippedScript }
                var from = -1   // source cell of a split-word match
                if i >= 2, let mg = merged[i - 1] {
                    let sim2 = mergedSpokenSimilarity(mg, ti)
                    if sim2 > 0 {
                        let src = (i - 2) * w + j - 1
                        let gain = sim2 * doc.weights[ti]
                        if H[src] + gain > best {
                            best = H[src] + gain; op = .mergedSpoken; from = src
                            matches = M[src] + 1
                            recent = R[src] + (i > recentFrom ? gain : 0)
                            start = S[src] >= 0 ? S[src] : Int32(ti)
                        }
                    }
                }
                if j >= 2 {
                    let sim2 = mergedScriptSimilarity(s, ti)
                    if sim2 > 0 {
                        let src = prev + j - 2
                        let gain = sim2 * (doc.weights[ti - 1] + doc.weights[ti]) * 0.8
                        if H[src] + gain > best {
                            best = H[src] + gain; op = .mergedScript; from = src
                            matches = M[src] + 1
                            recent = R[src] + (i > recentFrom ? gain : 0)
                            start = S[src] >= 0 ? S[src] : Int32(ti - 1)
                        }
                    }
                }
                O[row + j] = op
                switch op {
                case .mergedSpoken, .mergedScript:
                    P[row + j] = P[from] + 1; K[row + j] = K[from]
                case .start:
                    P[row + j] = 0; K[row + j] = 0
                case .match:
                    // Little words ("one", "your") repeat everywhere, so they don't back up a jump.
                    P[row + j] = P[prev + j - 1] + (doc.isStopword[ti] ? 0 : 1); K[row + j] = K[prev + j - 1]
                case .mismatch:
                    P[row + j] = P[prev + j - 1]; K[row + j] = K[prev + j - 1]
                case .extraSpoken:
                    P[row + j] = P[prev + j]; K[row + j] = K[prev + j]
                case .skippedScript:
                    P[row + j] = 0
                    K[row + j] = O[row + j - 1] == .skippedScript ? K[row + j - 1] + 1 : 1
                }
                H[row + j] = best
                M[row + j] = matches
                R[row + j] = recent
                S[row + j] = start
            }
        }

        // The alignment must reach (nearly) the newest spoken word, otherwise it describes the past.
        // Leaving the newest words unexplained costs more when they're real words, not "the".
        func unexplainedCost(_ k: Int) -> Float {
            let t = spoken[k].text
            return TextNormalizer.stopwords.contains(t) || t.count < 4 ? 0.25 : 0.7
        }
        let endings: [(Int, Float)] = [
            (0, 0),
            (1, unexplainedCost(m - 1)),
            (2, m >= 2 ? unexplainedCost(m - 1) + unexplainedCost(m - 2) : 0),
        ]
        var result: Candidate? = nil
        var singleResult: Candidate? = nil
        for j in 1...L {
            let next = lo + j
            let delta = next - position
            for (rowBack, penalty) in endings where m - rowBack >= 1 {
                let idx = (m - rowBack) * w + j
                // Only stop right after a word we actually heard. Ending on a misheard or ad-libbed
                // word would claim the script word there was said.
                guard O[idx].isMatch else { continue }
                let score = H[idx] - penalty
                let matches = Int(M[idx])
                let recent = R[idx]
                let st = Int(S[idx])
                // Restarting a sentence after a flub (or skipping to the next one) lands on a sentence start.
                let atSentenceStart = st >= 0 && (doc.sentenceStartTokens.contains(st) || doc.sentenceStartTokens.contains(st - 1))
                // Reading on word by word: the newest word alone is enough evidence for a tiny step.
                let recentNeeded: Float = delta > 14 || delta < -2 ? 1.0 : (delta <= 3 ? 0.4 : 0.75)
                let normal = (delta == 0 || recent >= recentNeeded)
                    && passes(score: score, matches: matches, delta: delta, strict: strict, sentenceStart: atSentenceStart)
                // Skipped a few words: one distinctive word that occurs only once nearby is enough to jump.
                let singleWordJump = !strict && matches >= 1 && delta >= 2 && delta <= 12 && recent >= 0.8
                    && isDistinctiveNearPosition(next - 1)
                guard score > 0, normal || singleWordJump else { continue }
                // Jumps backed by one word only count while that word is still the newest one heard.
                let tentative = !normal || (delta > 3 && K[idx] >= 2 && P[idx] <= 1)
                if tentative && (strict || rowBack > 0) { continue }
                let adjusted = score
                    - 0.008 * Float(max(0, delta - 6))
                    - 0.02 * Float(max(0, -delta))
                if !tentative {
                    if adjusted > (result?.adjusted ?? -.infinity) {
                        result = Candidate(next: next, score: score, matches: matches, recent: recent, adjusted: adjusted, cell: idx)
                    }
                } else if adjusted > (singleResult?.adjusted ?? -.infinity) {
                    singleResult = Candidate(next: next, score: score, matches: matches, recent: recent, adjusted: adjusted,
                                             single: true, cell: idx)
                }
            }
        }

        func heard(from cell: Int) -> [Int] {
            var out: [Int] = []
            var i = cell / w, j = cell % w
            while i > 0 && j > 0 {
                switch O[i * w + j] {
                case .start: i = 0
                case .match: out.append(lo + j - 1); i -= 1; j -= 1
                // Misheard, but you clearly said something there between words we did hear.
                case .mismatch: out.append(lo + j - 1); i -= 1; j -= 1
                case .mergedSpoken: out.append(lo + j - 1); i -= 2; j -= 1
                case .mergedScript: out.append(lo + j - 1); out.append(lo + j - 2); i -= 1; j -= 2
                case .extraSpoken: i -= 1
                case .skippedScript: j -= 1
                }
            }
            return out.reversed()
        }
        if let c = result?.cell { result?.heard = heard(from: c) }
        if let c = singleResult?.cell { singleResult?.heard = heard(from: c) }
        return (result, singleResult)
    }

    private func isDistinctiveNearPosition(_ t: Int) -> Bool {
        guard t >= 0, t < doc.tokens.count, doc.weights[t] >= 0.8, doc.tokens[t].count >= 5 else { return false }
        let word = doc.tokens[t]
        let lo = max(0, position - 10), hi = min(doc.tokens.count, position + 40)
        var n = 0
        for i in lo..<hi where doc.tokens[i] == word { n += 1 }
        return n == 1
    }

    private func passes(score: Float, matches: Int, delta: Int, strict: Bool, sentenceStart: Bool) -> Bool {
        if strict {
            return matches >= 4 && score >= 2.6
        }
        if sentenceStart && (delta < -2 || delta > 14) && matches >= 3 && score >= 1.8 {
            return true
        }
        switch delta {
        case -2...14:
            return matches >= 2 && score >= 1.05
        case 15...:
            return matches >= 3 && score >= min(3.0, 1.6 + 0.012 * Float(delta - 14))
        case -6 ..< -2:
            return matches >= 3 && score >= 1.9
        default:
            // Re-reading an earlier sentence: needs a solid run of words (or three rare ones).
            let need = min(3.2, 2.3 + 0.005 * Float(-delta))
            return (matches >= 4 && score >= need) || (matches >= 3 && score >= need + 0.3)
        }
    }
}
