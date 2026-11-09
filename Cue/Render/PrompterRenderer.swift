import CoreGraphics
import CoreText
import Foundation

/// Everything needed to draw one frame of the prompter.
struct PrompterFrame {
    enum Indicator: Equatable {
        case listening(Float)
        case paused
        case tilt
        case auto
        case problem
    }

    var size: CGSize                 // logical canvas size in points
    var scriptSize: CGSize           // the script area, from the top-left corner
    var pinnedRect: CGRect           // the pinned talking points strip, under the script
    var doc: ScriptDocument
    var layout: PrompterLayout
    var padX: CGFloat
    var scriptTop: CGFloat           // where the script text starts within its area
    var scrollY: CGFloat             // content y shown at the top of the script area
    var spoken: SpokenMarks          // which words are said, and how far along their fade is
    var now: Double
    var dimSpoken: Bool
    var readingLineY: CGFloat        // absolute y of the reading line

    var pointsLayout: PointsTextLayout?  // non-nil in "Points" mode
    var pointsScroll: CGFloat
    var pinnedPoints: [String]       // non-empty in "Script + Points" mode
    var pinnedFontSize: CGFloat
    var currentPoint: Int

    var indicator: Indicator
    var progress: Double
    var toast: String?
    var toastAlpha: CGFloat
}

enum PrompterRenderer {

    static let background = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let accent = CGColor(red: 1, green: 0.78, blue: 0.16, alpha: 1)     // warm yellow
    static let green = CGColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    static let orange = CGColor(red: 1, green: 0.58, blue: 0.0, alpha: 1)

    static func white(_ a: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: a) }

    /// Draws into a context whose origin is top-left with y pointing down (UIKit convention).
    static func draw(_ f: PrompterFrame, in ctx: CGContext) {
        let W = f.size.width, H = f.size.height
        ctx.saveGState()
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        if let pl = f.pointsLayout {
            drawPointsOnly(f, pl, ctx)
        } else {
            drawScript(f, ctx)
            if !f.pinnedPoints.isEmpty { drawPinned(f, ctx) }
        }

        drawChrome(f, ctx)
        ctx.restoreGState()
    }

    // MARK: Script

    private static func drawScript(_ f: PrompterFrame, _ ctx: CGContext) {
        let L = f.layout
        let W = f.scriptSize.width, H = f.scriptSize.height
        let areaTop = f.scriptTop
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: areaTop, width: W, height: H - areaTop))

        // Said words ease down to a soft grey; the darkening fades in rather than snapping.
        let dimBy: CGFloat = f.dimSpoken ? 0.8 : 0
        let upcoming = white(1)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        // Visible line range.
        let topY = f.scrollY - L.lineHeight
        let bottomY = f.scrollY + (H - areaTop) + L.lineHeight
        var li = max(0, L.lineIndex(forWord: Int(L.position(forY: max(0, topY)))))
        let baselineOffset = (L.lineHeight - (L.ascent + L.descent)) / 2 + L.ascent
        while li < L.lines.count {
            let line = L.lines[li]
            if line.y > bottomY { break }
            let screenY = areaTop + (line.y - f.scrollY)
            let text = NSMutableAttributedString()
            for w in line.first..<line.end {
                if w > line.first { text.append(NSAttributedString(string: " ", attributes: [fontKey: L.font])) }
                let a = dimBy > 0 ? f.spoken.amount(w, now: f.now) : 0
                let color = a > 0 ? white(1 - dimBy * a) : upcoming
                text.append(NSAttributedString(string: f.doc.words[w].text, attributes: [fontKey: L.font, colorKey: color]))
            }
            let ctLine = CTLineCreateWithAttributedString(text)
            ctx.textPosition = CGPoint(x: f.padX, y: screenY + baselineOffset)
            CTLineDraw(ctLine, ctx)
            li += 1
        }

        // The already-said line fades out at the top as it glides away. The bottom stays crisp.
        let fadeEnd = f.readingLineY - L.lineHeight * PrompterEngine.readingBand / 2 - 2
        fadeTop(ctx, from: areaTop, to: max(areaTop + 1, fadeEnd), width: W)
        ctx.restoreGState()
    }

    private static func fadeTop(_ ctx: CGContext, from y0: CGFloat, to y1: CGFloat, width: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [background, CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray
        guard let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: y0, width: width, height: y1 - y0))
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
        ctx.restoreGState()
    }

    // MARK: Points

    /// The pinned strip under the script: the current point (yellow dash) and the next one.
    private static func drawPinned(_ f: PrompterFrame, _ ctx: CGContext) {
        let r = f.pinnedRect
        guard r.width > 0, r.height > 0 else { return }
        let size = f.pinnedFontSize
        let font = PrompterFont.make(size: size)
        let rowH = ceil(size * 1.45)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let ascent = CTFontGetAscent(font)
        let dashW = size * 1.2
        let left = f.padX
        // Keep clear of the voice dot in the corner.
        let maxW = Double(r.maxX - f.padX - 18 - left - dashW)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [fontKey: font, colorKey: white(0.5)]))

        // Hairline between the script and the points.
        ctx.setFillColor(white(0.16))
        ctx.fill(CGRect(x: f.padX, y: r.minY + 2, width: f.size.width - f.padX * 2, height: 1))

        for (k, idx) in pinnedRows(count: f.pinnedPoints.count, current: f.currentPoint).enumerated() {
            let y = r.minY + 10 + CGFloat(k) * rowH
            let isCurrent = idx == f.currentPoint
            let dash = NSAttributedString(string: "–", attributes: [fontKey: font, colorKey: isCurrent ? accent : white(0.35)])
            ctx.textPosition = CGPoint(x: left, y: y + ascent)
            CTLineDraw(CTLineCreateWithAttributedString(dash), ctx)
            let text = NSAttributedString(string: f.pinnedPoints[idx],
                                          attributes: [fontKey: font, colorKey: isCurrent ? white(1) : white(0.5)])
            let line = CTLineCreateWithAttributedString(text)
            ctx.textPosition = CGPoint(x: left + dashW, y: y + ascent)
            CTLineDraw(CTLineCreateTruncatedLine(line, maxW, .end, ellipsis) ?? line, ctx)
        }
    }

    /// Which points to show in the pinned strip: the current one and the next (the last two at the end).
    static func pinnedRows(count: Int, current: Int) -> [Int] {
        guard count > 0 else { return [] }
        if count <= 2 { return Array(0..<count) }
        let start = min(max(0, current), count - 2)
        return [start, start + 1]
    }

    static func pinnedHeight(count: Int, fontSize: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return 10 + CGFloat(min(2, count)) * ceil(fontSize * 1.45) + 6
    }

    private static func drawPointsOnly(_ f: PrompterFrame, _ pl: PointsTextLayout, _ ctx: CGContext) {
        let W = f.size.width, H = f.size.height
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let indent = pl.lineHeight * 0.9
        let topPad: CGFloat = 18

        for (k, item) in pl.items.enumerated() {
            let y = topPad + item.y - f.pointsScroll
            if y + item.height < 0 || y > H { continue }
            let isCurrent = k == f.currentPoint
            let dash = NSAttributedString(string: "–", attributes: [fontKey: pl.font, colorKey: isCurrent ? accent : white(0.3)])
            ctx.textPosition = CGPoint(x: f.padX, y: y + pl.ascent)
            CTLineDraw(CTLineCreateWithAttributedString(dash), ctx)
            for (i, text) in item.lines.enumerated() {
                let a = NSAttributedString(string: text, attributes: [fontKey: pl.font, colorKey: isCurrent ? white(1) : white(0.42)])
                ctx.textPosition = CGPoint(x: f.padX + indent, y: y + CGFloat(i) * pl.lineHeight + pl.ascent)
                CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
            }
        }
    }

    // MARK: Chrome

    private static func drawChrome(_ f: PrompterFrame, _ ctx: CGContext) {
        let W = f.size.width, H = f.size.height

        // Progress hairline.
        if f.progress > 0 {
            ctx.setFillColor(white(0.1))
            ctx.fill(CGRect(x: 0, y: H - 3, width: W, height: 3))
            ctx.setFillColor(accent)
            ctx.fill(CGRect(x: 0, y: H - 3, width: W * CGFloat(min(1, f.progress)), height: 3))
        }

        // Status dot, bottom right, set in from the window's rounded corner. Quiet: a small grey dot.
        // Hearing you: the same dot turns green. No growing, no halo — nothing to pull your eye.
        let center = CGPoint(x: W - 18, y: H - 18)
        let r: CGFloat = 4.5
        var color: CGColor
        switch f.indicator {
        case .listening(let level):
            let on = min(1, max(0, CGFloat(level))) // 0 quiet … 1 hearing you
            color = CGColor(red: 0.42 - 0.23 * on, green: 0.42 + 0.40 * on, blue: 0.42 - 0.07 * on, alpha: 0.9)
        case .paused: color = white(0.45)
        case .tilt, .auto: color = accent
        case .problem: color = orange
        }
        ctx.setFillColor(color)
        if f.indicator == .paused {
            // Two small bars.
            ctx.fill(CGRect(x: center.x - 4.5, y: center.y - 5, width: 3, height: 10))
            ctx.fill(CGRect(x: center.x + 1.5, y: center.y - 5, width: 3, height: 10))
        } else {
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }

        // Command toast.
        if let toast = f.toast, f.toastAlpha > 0.01 {
            let font = PrompterFont.make(size: 15)
            let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
            let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: toast, attributes: [fontKey: font, colorKey: white(f.toastAlpha)]))
            let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let pill = CGRect(x: (W - tw) / 2 - 14, y: H - 46, width: tw + 28, height: 30)
            ctx.setFillColor(CGColor(red: 0.18, green: 0.18, blue: 0.2, alpha: 0.95 * f.toastAlpha))
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 15, cornerHeight: 15, transform: nil))
            ctx.fillPath()
            ctx.textPosition = CGPoint(x: pill.minX + 14, y: pill.midY + CTFontGetAscent(font) / 2 - 2)
            CTLineDraw(line, ctx)
        }
    }
}
