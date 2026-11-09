import Foundation

// Simulates a person reading with a noisy speech recognizer and measures how well the follower keeps up.
// Build & run:  swiftc -O -o /tmp/cue-harness Cue/Engine/*.swift EngineTests/main.swift && /tmp/cue-harness

struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

let baseScript = """
So, there are thousands of videos about filming yourself at home. And most of them honestly just tell you to buy more gear.

But, after recording over 70,000 takes in a spare room, I found 6 habits that matter more than any camera. And some of them cost less than $5.

The first one is light. Turn your face toward a window and switch off the lights above you. Think of the window as a giant soft box that you get for free. If the sun moves, you move with it, and you never record with a bright window behind you.

Number two is sound. People will forgive a blurry picture, but they click away from bad audio in seconds. So put the microphone close to your mouth, hang a thick towel on the wall behind the camera, and switch off the fridge before you press record.

Number three is framing. Keep your eyes about a third of the way down the screen and leave a little room above your head. Your viewers stay focused on your face instead of the ceiling.

The fourth thing is a script. Before you film a single take, you write it down. You read it out loud, you cut every line that sounds stiff, and you keep the ones that sound like you. It feels slower, but it saves you hours of editing out the mistakes.

Number five, and this one is underrated, is energy. You lose some of your energy through the lens, so talk a little louder and a little faster than feels natural. It looks normal on screen, even when it feels silly in the room.

And the last one is consistency. Pick a day, pick a time, and post every single week. You decide it once, and from then on the habit carries you, even on the days you don't feel like filming.

If you only take one thing from this video, move your desk next to a window today. It takes ten minutes and it pays you back on every single video. Let me know in the comments which one you're going to try first.
"""

let soundAlikes: [String: [String]] = [
    "light": ["like", "lied", "night"], "there": ["their", "they're"], "sound": ["sounds", "found"],
    "script": ["scripts", "crypt"], "window": ["windows", "widow"], "framing": ["flaming", "framed"],
    "habits": ["habit", "rabbits"], "takes": ["take", "steaks"], "energy": ["energies"], "week": ["weak"],
    "four": ["for"], "two": ["to", "too"], "know": ["no"], "one": ["won"], "write": ["right"],
]
let randomWords = ["okay", "actually", "basically", "really", "right", "yeah", "guys", "literally", "anyway"]

struct Spoken { let text: String; let truePos: Int } // truePos: next script token after this word

/// Turns the script into a noisy stream of recognizer words, each tagged with where the reader truly is.
func simulateReading(_ doc: ScriptDocument, rng: inout RNG, errorRate: Double, skipSentences: Bool, restarts: Bool) -> [Spoken] {
    var out: [Spoken] = []
    var w = 0
    let starts = Set(doc.sentenceStarts)
    while w < doc.words.count {
        // Occasionally skip a whole sentence.
        if skipSentences, starts.contains(w), w > 30, Double.random(in: 0..<1, using: &rng) < 0.06 {
            w = doc.nextSentenceStart(after: w)
            continue
        }
        // Occasionally flub and restart the current sentence.
        if restarts, starts.contains(w) == false, Double.random(in: 0..<1, using: &rng) < 0.012 {
            let s = doc.sentenceStart(containing: w)
            if w - s >= 4 {
                out.append(Spoken(text: "sorry", truePos: doc.tokenIndex(forWord: w)))
                w = s
                continue
            }
        }
        let word = doc.words[w]
        let toks = TextNormalizer.tokens(forWord: word.text)
        // Recognizers usually print numbers as digits; keep the original form for those words.
        let isNumber = word.text.first?.isNumber == true
        let r = Double.random(in: 0..<1, using: &rng)
        let truePos = word.tokenRange.upperBound
        if isNumber {
            out.append(Spoken(text: word.text.replacingOccurrences(of: ",", with: ""), truePos: truePos))
        } else if r < errorRate * 0.45, let t = toks.first {
            // Misheard: sound-alike if we have one, else a random word.
            let sub = soundAlikes[t]?.randomElement(using: &rng) ?? randomWords.randomElement(using: &rng)!
            out.append(Spoken(text: sub, truePos: truePos))
        } else if r < errorRate * 0.75 {
            // Dropped by the recognizer.
        } else if r < errorRate {
            out.append(Spoken(text: word.text, truePos: truePos))
            out.append(Spoken(text: Bool.random(using: &rng) ? "um" : randomWords.randomElement(using: &rng)!, truePos: truePos))
        } else {
            out.append(Spoken(text: word.text, truePos: truePos))
        }
        w += 1
    }
    return out
}

struct Stats {
    var updates = 0, within2 = 0, within5 = 0, bigErrors = 0, maxLagAtEnd = 0, ahead = 0
    var lagSum = 0
    var finalPos = 0
}

func run(name: String, text: String, seed: UInt64, errorRate: Double, skip: Bool, restarts: Bool, taskReset: Int = 70) -> Stats {
    var rng = RNG(state: seed)
    let doc = ScriptDocument(text: text)
    let aligner = SpeechAligner(doc: doc)
    let stream = simulateReading(doc, rng: &rng, errorRate: errorRate, skipSentences: skip, restarts: restarts)
    var hyp: [String] = []
    var stats = Stats()
    for s in stream {
        let toks = TextNormalizer.tokens(forWord: s.text)
        // Partial results show half-spoken words first.
        if let first = toks.first, first.count > 5 {
            aligner.update(hypothesis: hyp + [String(first.prefix(first.count / 2 + 1))])
        }
        hyp.append(contentsOf: toks)
        aligner.update(hypothesis: hyp)
        if hyp.count > taskReset && Int.random(in: 0..<10, using: &rng) == 0 {
            hyp = []
            aligner.newUtterance()
        }
        let err = s.truePos - aligner.position
        stats.updates += 1
        if abs(err) <= 2 { stats.within2 += 1 }
        if abs(err) <= 5 { stats.within5 += 1 }
        if abs(err) > 12 { stats.bigErrors += 1 }
        if err < 0 { stats.ahead += 1 }
        stats.lagSum += abs(err)
        if ProcessInfo.processInfo.environment["TRACE"] == name, abs(err) > 5 {
            let ctx = doc.tokens[max(0, s.truePos - 6)..<min(doc.tokens.count, s.truePos)].joined(separator: " ")
            print("   err \(err) heard '\(s.text)' true \(s.truePos) at [..\(ctx)] aligner \(aligner.position) hypTail \(hyp.suffix(8).joined(separator: " "))")
        }
    }
    stats.finalPos = aligner.position
    let pct = { (n: Int) in String(format: "%.1f%%", 100 * Double(n) / Double(max(1, stats.updates))) }
    print("\(name.padding(toLength: 34, withPad: " ", startingAt: 0)) ±2: \(pct(stats.within2))  ±5: \(pct(stats.within5))  off>12: \(pct(stats.bigErrors))  ahead: \(pct(stats.ahead))  mean|err|: \(String(format: "%.2f", Double(stats.lagSum) / Double(max(1, stats.updates))))  end: \(aligner.position)/\(doc.tokens.count)")
    return stats
}

print("== Normalizer ==")
for s in ["70,000", "$5", "6", "don't", "README.md", "well-known", "50%", "3.5", "1st", "4K", "R&D", "you'd"] {
    print("  \(s) → \(TextNormalizer.tokens(forWord: s))")
}
for (a, b) in [("light", "lite"), ("there", "their"), ("knight", "night"), ("phone", "fone"), ("mic", "mike")] {
    print("  phonetic \(a)=\(TextNormalizer.phonetic(a)) \(b)=\(TextNormalizer.phonetic(b))")
}

print("\n== Follow accuracy (5 seeds each) ==")
for seed: UInt64 in [1, 7, 42, 99, 2024] {
    _ = run(name: "clean read seed \(seed)", text: baseScript, seed: seed, errorRate: 0.0, skip: false, restarts: false)
}
for seed: UInt64 in [1, 7, 42, 99, 2024] {
    _ = run(name: "10% recognizer noise seed \(seed)", text: baseScript, seed: seed, errorRate: 0.10, skip: false, restarts: false)
}
for seed: UInt64 in [1, 7, 42, 99, 2024] {
    _ = run(name: "20% noise+skips+restarts \(seed)", text: baseScript, seed: seed, errorRate: 0.20, skip: true, restarts: true)
}
for seed: UInt64 in [3, 5] {
    _ = run(name: "35% noise (very bad mic) \(seed)", text: baseScript, seed: seed, errorRate: 0.35, skip: false, restarts: true)
}

print("\n== Long script ==")
var long = ""
var lr = RNG(state: 11)
let vocab = TextNormalizer.tokens(baseScript)
for p in 0..<600 {
    var para: [String] = []
    for _ in 0..<90 { para.append(vocab.randomElement(using: &lr)!) }
    long += "Section \(p + 1). " + para.joined(separator: " ") + ".\n\n"
}
let t0 = Date()
let longDoc = ScriptDocument(text: long)
print("parsed \(longDoc.words.count) words in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
let la = SpeechAligner(doc: longDoc)
// Jump: speaker starts reading somewhere deep in the script without telling us.
let target = longDoc.tokenIndex(forWord: 40_000)
var h: [String] = []
let t1 = Date()
var found = -1
for k in 0..<25 {
    h.append(longDoc.tokens[target + k])
    la.update(hypothesis: h)
    if abs(la.position - (target + k + 1)) <= 2 { found = k + 1; break }
}
print("re-found place 40,000 words in after \(found) spoken words (\(String(format: "%.1f", Date().timeIntervalSince(t1) * 1000)) ms total)")
let t2 = Date()
for k in 25..<1025 { h.append(longDoc.tokens[target + k]); la.update(hypothesis: Array(h.suffix(60))) }
print("1000 updates on long script: \(String(format: "%.2f", Date().timeIntervalSince(t2) * 1000 / 1000)) ms per update, pos err \(target + 1025 - la.position)")

print("\n== Commands ==")
let cdoc = ScriptDocument(text: baseScript)
for phrase in ["okay go back to the top", "back two lines", "go back", "go back three lines", "skip ahead please",
               "back to lines", "let me try that again", "next point", "and the last one is consistency"] {
    let hyp = TextNormalizer.tokens(phrase)
    if let m = VoiceCommands.find(in: hyp, from: 0) {
        let inScript = VoiceCommands.phrase(m.phrase, appearsIn: cdoc, near: cdoc.tokens.count - 30)
        print("  \"\(phrase)\" → \(m.command.label)\(m.mightGrow ? " (wait)" : "")\(inScript ? " [in script → ignored]" : "")")
    } else {
        print("  \"\(phrase)\" → none")
    }
}

print("\n== Talking points ==")
let pt = PointTracker(points: ["Intro: too much gear advice", "Light from a window", "Sound and the microphone", "Framing your eyes"])
var ph: [String] = []
for sentence in ["so most videos just tell you to buy more gear", "first up face the window it's the best light you can get",
                 "now sound matters more than the picture so get the microphone close", "and then framing keep your eyes a third of the way down"] {
    ph += TextNormalizer.tokens(sentence)
    pt.update(hypothesis: ph)
    print("  \"\(sentence)\" → point \(pt.current + 1)")
}

print("\n== Skipping a few words mid-sentence ==")
do {
    let doc = ScriptDocument(text: baseScript)
    for skip in [2, 3, 5, 8] {
        var total = 0, cases = 0, never = 0
        for s in doc.sentenceStarts where s + 4 + skip + 6 < doc.words.count {
            let a = SpeechAligner(doc: doc)
            var hyp: [String] = []
            // Read the first 4 words normally.
            for w in s..<(s + 4) { hyp += TextNormalizer.tokens(forWord: doc.words[w].text) }
            a.move(toToken: doc.tokenIndex(forWord: s), hypothesisCount: 0)
            a.update(hypothesis: hyp)
            // Skip `skip` words, then keep reading; count words until the follower is on the right word.
            var caught = -1
            for (k, w) in ((s + 4 + skip)..<(s + 4 + skip + 6)).enumerated() {
                hyp += TextNormalizer.tokens(forWord: doc.words[w].text)
                // Live results arrive a few times per word (refined in place).
                a.update(hypothesis: hyp)
                a.update(hypothesis: hyp)
                if abs(a.wordPosition - (w + 1)) <= 1 { caught = k + 1; break }
            }
            if caught < 0 { never += 1 } else { total += caught; cases += 1 }
        }
        print("  skip \(skip) words → caught up after \(String(format: "%.2f", Double(total) / Double(max(1, cases)))) words on average (\(never) not within 6)")
    }
}

print("\n== Never mark words that weren't said ==")
do {
    let doc = ScriptDocument(text: baseScript)
    func toks(_ w: Int) -> [String] { TextNormalizer.tokens(forWord: doc.words[w].text) }
    func isContent(_ w: Int) -> Bool {
        let t = toks(w)
        return t.count == 1 && t[0].count >= 5 && !TextNormalizer.stopwords.contains(t[0])
    }

    // 1. Say a different word instead of a script word ("blanket" for "teleprompter").
    var cases = 0, passedEarly = 0, markedHeard = 0, lostAfter = 0
    for s in doc.sentenceStarts {
        let target = s + 4
        guard target + 3 < doc.words.count, isContent(target),
              doc.sentenceStart(containing: target + 3) == s else { continue }
        cases += 1
        let a = SpeechAligner(doc: doc)
        a.move(toToken: doc.tokenIndex(forWord: s), hypothesisCount: 0)
        var hyp: [String] = []
        for w in s..<target { hyp += toks(w); a.update(hypothesis: hyp) }
        hyp.append("blanket")
        a.update(hypothesis: hyp)
        if a.wordPosition > target { passedEarly += 1 }
        for w in (target + 1)...(target + 2) { hyp += toks(w); a.update(hypothesis: hyp) }
        let heardWords = Set(a.heardTokens.map { doc.wordIndex(forToken: $0) })
        if heardWords.contains(target) { markedHeard += 1 }
        if abs(a.wordPosition - (target + 3)) > 1 { lostAfter += 1 }
    }
    print("  substituted word: \(cases) cases · moved past it early \(passedEarly) · shown as said \(markedHeard) · lost after \(lostAfter)")

    // 2. An aside that happens to use a word from a few words ahead, then reading on normally.
    cases = 0
    var jumped = 0
    for s in doc.sentenceStarts {
        guard s + 14 < doc.words.count else { continue }
        guard let later = ((s + 7)...(s + 12)).first(where: { isContent($0) }) else { continue }
        cases += 1
        let a = SpeechAligner(doc: doc)
        a.move(toToken: doc.tokenIndex(forWord: s), hypothesisCount: 0)
        var hyp: [String] = []
        for w in s..<(s + 3) { hyp += toks(w); a.update(hypothesis: hyp) }
        hyp += toks(later)
        a.update(hypothesis: hyp)
        var maxPos = a.wordPosition
        for w in (s + 3)..<(s + 5) { hyp += toks(w); a.update(hypothesis: hyp); maxPos = max(maxPos, a.wordPosition) }
        if maxPos > s + 6 {
            jumped += 1
            if ProcessInfo.processInfo.environment["TRACE"] == "aside" {
                print("    aside: read '\((s..<(s + 3)).map { doc.words[$0].text }.joined(separator: " "))' + '\(doc.words[later].text)' then '\(doc.words[s + 3].text) \(doc.words[s + 4].text)' → at word \(maxPos - s)")
            }
        }
    }
    print("  aside with a later word: \(cases) cases · jumped ahead \(jumped)")

    // 3. A live result guesses a later word, then corrects itself on the next update.
    cases = 0
    jumped = 0
    for s in doc.sentenceStarts {
        guard s + 14 < doc.words.count else { continue }
        guard let later = ((s + 6)...(s + 12)).first(where: { isContent($0) }) else { continue }
        cases += 1
        let a = SpeechAligner(doc: doc)
        a.move(toToken: doc.tokenIndex(forWord: s), hypothesisCount: 0)
        var hyp: [String] = []
        for w in s..<(s + 3) { hyp += toks(w); a.update(hypothesis: hyp) }
        a.update(hypothesis: hyp + toks(later))     // wrong guess
        let first = a.wordPosition
        hyp += toks(s + 3)
        a.update(hypothesis: hyp)                   // corrected
        if first > s + 4 || a.wordPosition > s + 5 {
            jumped += 1
            if ProcessInfo.processInfo.environment["TRACE"] == "flicker" {
                print("    flicker: '\((s..<(s + 3)).map { doc.words[$0].text }.joined(separator: " "))' + guess '\(doc.words[later].text)' (word \(later - s)) → \(first - s), then '\(doc.words[s + 3].text)' → \(a.wordPosition - s)")
            }
        }
    }
    print("  flickering wrong guess: \(cases) cases · jumped ahead \(jumped)")

    // 4. Clean reading: every word read should be shown as said.
    let a = SpeechAligner(doc: doc)
    var hyp: [String] = []
    var heardAll = Set<Int>()
    for w in 0..<doc.words.count {
        hyp += toks(w)
        if a.update(hypothesis: hyp) { heardAll.formUnion(a.heardTokens.map { doc.wordIndex(forToken: $0) }) }
        if hyp.count > 60 { hyp = []; a.newUtterance() }
    }
    print("  clean read: \(heardAll.count)/\(doc.words.count) words shown as said")
}

print("\n== Hard words the recognizer mishears ==")
do {
    let text = "Hi! This is Cue, a teleprompter that floats over your camera. Today I set up Kubernetes on GitHub with ChatGPT, then Anthropic subagents wrote the YouTube thumbnail. Cue keeps up."
    let doc = ScriptDocument(text: text)
    // What a recognizer might print for each hard word.
    let heardAs: [String: [String]] = [
        "Cue,": ["queue", "q", "kew", "cue"], "Cue": ["queue", "q", "kew"],
        "teleprompter": ["tele prompter", "teleprompter", "tell a prompter"],
        "Kubernetes": ["cooper netties", "kubernetes", "cuber netes"],
        "GitHub": ["git hub", "github"],
        "ChatGPT,": ["chat gpt", "chatgpt", "chat g p t"],
        "Anthropic": ["entropic", "anthropic", "and tropic"],
        "subagents": ["sub agents", "subagent"],
        "YouTube": ["you tube", "youtube"],
    ]
    var cases = 0, caughtNow = 0, caughtNext = 0, shownSaid = 0
    var misses: [String] = []
    for (w, word) in doc.words.enumerated() {
        guard let variants = heardAs[word.text] else { continue }
        for v in variants {
            cases += 1
            let a = SpeechAligner(doc: doc)
            var hyp: [String] = []
            for k in 0..<w { hyp += TextNormalizer.tokens(forWord: doc.words[k].text); a.update(hypothesis: hyp) }
            var heard = Set<Int>()
            hyp += TextNormalizer.tokens(v)
            if a.update(hypothesis: hyp) { heard.formUnion(a.heardTokens.map { doc.wordIndex(forToken: $0) }) }
            let now = a.wordPosition >= w + 1
            if now { caughtNow += 1 }
            if w + 1 < doc.words.count {
                hyp += TextNormalizer.tokens(forWord: doc.words[w + 1].text)
                if a.update(hypothesis: hyp) { heard.formUnion(a.heardTokens.map { doc.wordIndex(forToken: $0) }) }
            }
            if a.wordPosition >= w + 2 || now { caughtNext += 1 } else { misses.append("\(word.text)←'\(v)' at \(a.wordPosition - w)") }
            if heard.contains(w) { shownSaid += 1 }
        }
    }
    print("  \(cases) mishearings · followed right away \(caughtNow) · by the next word \(caughtNext) · shown as said \(shownSaid)")
    if !misses.isEmpty { print("  missed: \(misses.joined(separator: ", "))") }
}
