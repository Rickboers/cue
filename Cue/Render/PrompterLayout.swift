import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PrompterFont {
    static func make(size: CGFloat, bold: Bool = true) -> CTFont {
        #if canImport(UIKit)
        return UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
        #else
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
        #endif
    }
}

/// Measures words once and caches the result; long scripts repeat a lot of words.
final class WordMeasurer {
    let font: CTFont
    private var cache: [String: CGFloat] = [:]
    let spaceWidth: CGFloat

    init(font: CTFont) {
        self.font = font
        self.spaceWidth = Self.measure(" ", font: font)
    }

    func width(_ s: String) -> CGFloat {
        if let w = cache[s] { return w }
        let w = Self.measure(s, font: font)
        cache[s] = w
        return w
    }

    static func measure(_ s: String, font: CTFont) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// Word-wrapped lines for the whole script. Only visible lines are ever drawn,
/// so scripts of any length stay smooth.
final class PrompterLayout {

    struct Line {
        let first: Int  // first word index
        let end: Int    // one past the last word
        let y: CGFloat  // top of the line in content coordinates
    }

    let lines: [Line]
    let lineHeight: CGFloat
    let contentHeight: CGFloat
    let font: CTFont
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat
    let fontSize: CGFloat

    init(doc: ScriptDocument, fontSize: CGFloat, width: CGFloat, lineSpacing: CGFloat = 1.22) {
        let font = PrompterFont.make(size: fontSize)
        self.font = font
        self.fontSize = fontSize
        self.width = width
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        lineHeight = ceil((ascent + descent) * lineSpacing)
        let paragraphGap = lineHeight * 0.55
        let measurer = WordMeasurer(font: font)

        var lines: [Line] = []
        var y: CGFloat = 0
        var first = 0
        var x: CGFloat = 0
        let words = doc.words
        for (i, word) in words.enumerated() {
            let w = measurer.width(word.text)
            let forced = word.breakBefore != .none && i > first
            if i > first && (forced || x + measurer.spaceWidth + w > width) {
                lines.append(Line(first: first, end: i, y: y))
                y += lineHeight
                if word.breakBefore == .paragraph { y += paragraphGap }
                first = i
                x = w
            } else {
                x += (i > first ? measurer.spaceWidth : 0) + w
            }
        }
        if first < words.count {
            lines.append(Line(first: first, end: words.count, y: y))
            y += lineHeight
        }
        self.lines = lines
        contentHeight = y
    }

    func lineIndex(forWord w: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].first <= w { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Content y for a fractional word position. Moves smoothly across a line as it's read.
    func y(forPosition p: Double) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let w = max(0, Int(p.rounded(.down)))
        let li = lineIndex(forWord: w)
        let line = lines[li]
        let count = Double(max(1, line.end - line.first))
        let frac = min(1, max(0, (p - Double(line.first)) / count))
        let nextY = li + 1 < lines.count ? lines[li + 1].y : line.y + lineHeight
        return line.y + CGFloat(frac) * (nextY - line.y)
    }

    /// Inverse of `y(forPosition:)`, for dragging.
    func position(forY y: CGFloat) -> Double {
        guard !lines.isEmpty else { return 0 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].y <= y { lo = mid } else { hi = mid - 1 }
        }
        let line = lines[lo]
        let nextY = lo + 1 < lines.count ? lines[lo + 1].y : line.y + lineHeight
        let frac = Double(min(1, max(0, (y - line.y) / max(1, nextY - line.y))))
        return Double(line.first) + frac * Double(line.end - line.first)
    }
}

/// Talking points wrapped for the "Points" view.
final class PointsTextLayout {
    struct Item {
        let lines: [String]
        let y: CGFloat
        let height: CGFloat
    }

    let items: [Item]
    let font: CTFont
    let lineHeight: CGFloat
    let ascent: CGFloat
    let contentHeight: CGFloat

    init(points: [String], fontSize: CGFloat, width: CGFloat) {
        let font = PrompterFont.make(size: fontSize)
        self.font = font
        ascent = CTFontGetAscent(font)
        lineHeight = ceil((CTFontGetAscent(font) + CTFontGetDescent(font)) * 1.2)
        let gap = lineHeight * 0.7
        let measurer = WordMeasurer(font: font)
        var items: [Item] = []
        var y: CGFloat = 0
        for p in points {
            var lines: [String] = []
            var cur = ""
            var x: CGFloat = 0
            for word in p.split(separator: " ").map(String.init) {
                let w = measurer.width(word)
                if !cur.isEmpty && x + measurer.spaceWidth + w > width {
                    lines.append(cur)
                    cur = word
                    x = w
                } else {
                    cur += cur.isEmpty ? word : " " + word
                    x += (x > 0 ? measurer.spaceWidth : 0) + w
                }
            }
            if !cur.isEmpty { lines.append(cur) }
            let h = CGFloat(max(1, lines.count)) * lineHeight
            items.append(Item(lines: lines, y: y, height: h))
            y += h + gap
        }
        self.items = items
        contentHeight = y
    }
}
