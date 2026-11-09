import Foundation

/// Turns script text and recognizer output into the same comparable token stream.
/// Both sides go through the exact same path, so "70,000", "70000" and
/// "seventy thousand" all become ["seventy", "thousand"].
enum TextNormalizer {

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "erm", "er", "hmm", "mm", "ah", "eh"]

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "of", "to", "in", "on", "at", "for", "with", "is", "it",
        "its", "be", "are", "was", "were", "i", "you", "we", "they", "he", "she", "this", "that", "these",
        "those", "my", "your", "our", "me", "do", "does", "did", "not", "no", "yes", "as", "by", "from",
        "if", "then", "just", "like", "have", "has", "had", "will", "can", "all", "what", "which", "who",
        "how", "about", "up", "out", "there", "here", "them", "their", "im", "youre", "dont", "its", "thats",
    ]

    private static let ordinals: [String: String] = [
        "1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth", "5th": "fifth", "6th": "sixth",
        "7th": "seventh", "8th": "eighth", "9th": "ninth", "10th": "tenth", "11th": "eleventh",
        "12th": "twelfth", "13th": "thirteenth", "20th": "twentieth", "21st": "twenty first",
        "30th": "thirtieth", "31st": "thirty first", "100th": "hundredth",
    ]

    private static let symbolWords: [Character: String] = [
        "&": "and", "%": "percent", "+": "plus", "@": "at", "=": "equals", "#": "number",
    ]

    private static let spellOut: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        return f
    }()

    private static let lock = NSLock()
    private static var numberCache: [String: [String]] = [:]

    /// Normalized match tokens for a whole string.
    static func tokens(_ raw: String) -> [String] {
        var out: [String] = []
        for piece in raw.split(whereSeparator: { $0.isWhitespace }) {
            out.append(contentsOf: tokens(forWord: String(piece)))
        }
        return out
    }

    /// One whitespace-delimited word may expand into several tokens ("well-known", "$5", "70,000").
    static func tokens(forWord word: String) -> [String] {
        var w = word.lowercased()
        w = w.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")

        var out: [String] = []
        var prefixDollar = false
        var suffixPercent = false

        // Split on joiners that are spoken as separate words.
        let parts = w.split(whereSeparator: { "-–—/_".contains($0) })
        for partSub in parts {
            var part = String(partSub)
            if part.hasPrefix("$") { prefixDollar = true }
            if part.hasSuffix("%") { suffixPercent = true }

            // Pure symbol words.
            if part.count == 1, let c = part.first, let s = symbolWords[c] {
                out.append(s)
                continue
            }
            if let o = ordinals[part.trimmingCharacters(in: .punctuationCharacters)] {
                out.append(contentsOf: o.split(separator: " ").map(String.init))
                continue
            }

            // Strip everything except letters, digits, and a decimal point inside numbers.
            var cleaned = ""
            let chars = Array(part)
            for (i, c) in chars.enumerated() {
                if c.isLetter || c.isNumber {
                    cleaned.append(c)
                } else if c == "." || c == ",",
                          i > 0, i < chars.count - 1,
                          chars[i - 1].isNumber, chars[i + 1].isNumber {
                    if c == "." { cleaned.append(".") } // commas inside numbers are dropped
                } else if c == ".", i > 0, i < chars.count - 1, chars[i - 1].isLetter, chars[i + 1].isLetter {
                    // "README.md" is said "readme M D"; split like a word boundary.
                    if !cleaned.isEmpty { out.append(contentsOf: finish(cleaned)); cleaned = "" }
                } else if c == "&" {
                    if !cleaned.isEmpty { out.append(contentsOf: finish(cleaned)); cleaned = "" }
                    out.append("and")
                }
            }
            part = cleaned
            if part.isEmpty { continue }
            out.append(contentsOf: finish(part))
        }
        if prefixDollar { out.append("dollars") }
        if suffixPercent { out.append("percent") }
        return out
    }

    private static func finish(_ part: String) -> [String] {
        // Fold diacritics: "café" → "cafe".
        let folded = part.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
        if folded.first?.isNumber == true {
            return numberWords(folded)
        }
        return [folded]
    }

    /// "70000" → ["seventy", "thousand"], "3.5" → ["three", "point", "five"], "4k" → ["four", "k"].
    static func numberWords(_ s: String) -> [String] {
        lock.lock()
        if let cached = numberCache[s] { lock.unlock(); return cached }
        lock.unlock()

        var result: [String] = []
        // Split leading digits from a trailing letter suffix ("4k", "10x", "2am").
        let digits = s.prefix { $0.isNumber || $0 == "." }
        let suffix = s.dropFirst(digits.count)
        if let value = Double(digits), digits.count <= 15 {
            let spelled: String?
            if digits.contains(".") {
                spelled = spellOut.string(from: NSNumber(value: value))
            } else if let iv = Int(digits) {
                spelled = spellOut.string(from: NSNumber(value: iv))
            } else {
                spelled = nil
            }
            if let spelled {
                result = spelled
                    .replacingOccurrences(of: "-", with: " ")
                    .split(separator: " ")
                    .map(String.init)
            } else {
                result = [String(digits)]
            }
        } else {
            result = [String(digits)]
        }
        if !suffix.isEmpty { result.append(String(suffix)) }

        lock.lock()
        numberCache[s] = result
        lock.unlock()
        return result
    }

    /// A compact sound-alike key so recognizer slips ("light" → "lite", "there" → "their") still match.
    static func phonetic(_ token: String) -> String {
        if token.isEmpty { return token }
        if token.first?.isNumber == true { return token }
        var s = Array(token)
        var out: [Character] = []
        var i = 0
        func at(_ k: Int) -> Character? { k >= 0 && k < s.count ? s[k] : nil }

        // Common silent / merged starts.
        let str = String(s)
        if str.hasPrefix("kn") || str.hasPrefix("gn") || str.hasPrefix("pn") || str.hasPrefix("wr") {
            s.removeFirst()
        } else if str.hasPrefix("x") {
            s[0] = "s"
        } else if str.hasPrefix("wh") {
            s.remove(at: 1)
        }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        while i < s.count {
            let c = s[i]
            let next = at(i + 1)
            var emit: Character? = nil
            switch c {
            case "a", "e", "i", "o", "u", "y":
                // Keep only a leading vowel, as a generic marker.
                if i == 0 { emit = "a" }
            case "b":
                if !(i == s.count - 1 && at(i - 1) == "m") { emit = "b" }
            case "c":
                if next == "h" { emit = "x"; i += 1 }
                else if let n = next, "eiy".contains(n) { emit = "s" }
                else { emit = "k" }
            case "d":
                if next == "g", let n2 = at(i + 2), "eiy".contains(n2) { emit = "j"; i += 1 }
                else { emit = "t" }
            case "g":
                if next == "h" {
                    // "gh" is silent mostly ("night", "though"), sometimes f ("laugh"); treat as silent.
                    i += 1
                } else if next == "n" && (i + 2 == s.count) {
                    // "sign"
                } else if let n = next, "eiy".contains(n) { emit = "j" }
                else { emit = "k" }
            case "h":
                if let p = at(i - 1), !vowels.contains(p) { break }
                if let n = next, vowels.contains(n) { emit = "h" }
            case "k":
                if at(i - 1) != "c" { emit = "k" }
            case "p":
                if next == "h" { emit = "f"; i += 1 } else { emit = "p" }
            case "q": emit = "k"
            case "s":
                if next == "h" { emit = "x"; i += 1 }
                else if next == "c", at(i + 2) == "h" { out.append("s"); emit = "k"; i += 2 }
                else { emit = "s" }
            case "t":
                if next == "h" { emit = "0"; i += 1 }
                else if next == "i", let n2 = at(i + 2), n2 == "o" || n2 == "a" { emit = "x" }
                else { emit = "t" }
            case "v": emit = "f"
            case "w":
                if let n = next, vowels.contains(n) { emit = "w" }
            case "x": if out.last != "k" { out.append("k") }; emit = "s"
            case "z": emit = "s"
            default: emit = c
            }
            if let e = emit, out.last != e { out.append(e) }
            i += 1
        }
        return String(out)
    }

    /// Normalized similarity in 0...1 based on Levenshtein distance.
    static func editSimilarity(_ a: String, _ b: String) -> Float {
        if a == b { return 1 }
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.isEmpty || y.isEmpty { return 0 }
        if abs(x.count - y.count) > max(x.count, y.count) / 2 { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        let d = prev[y.count]
        return 1 - Float(d) / Float(max(x.count, y.count))
    }
}
