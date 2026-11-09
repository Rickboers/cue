import CoreGraphics
import Foundation
import Observation
import QuartzCore
import UIKit

/// Runs one prompting session: listens, follows, scrolls, and feeds both the in-app preview
/// and the floating Picture-in-Picture window from the same frames.
@Observable
final class PrompterEngine {

    // MARK: State the UI shows

    var title: String
    /// Width ÷ height of the prompter canvas (the in-app preview takes this shape).
    private(set) var canvasAspect: Double = 1.5
    let points: [String]
    var mode: FollowMode { didSet { if mode != oldValue { modeChanged() } } }
    var pointsLayout: PointsLayout { didSet { if pointsLayout != oldValue { geometryChanged() } } }
    private(set) var isPaused = false
    private(set) var isFloating = false
    private(set) var canFloat = false
    private(set) var hearing = false
    private(set) var problem: String?
    private(set) var progressPercent = 0
    private(set) var currentPoint = 0

    // MARK: Internals

    @ObservationIgnored let settings = PrompterSettings.shared
    @ObservationIgnored let doc: ScriptDocument
    @ObservationIgnored let spoken: SpokenMarks
    @ObservationIgnored let pip = PiPController()
    /// Asks the in-app canvas to redraw.
    @ObservationIgnored var onRedraw: (() -> Void)?

    @ObservationIgnored private let aligner: SpeechAligner
    @ObservationIgnored private let pointTracker: PointTracker
    @ObservationIgnored private let follower = SpeechFollower()
    @ObservationIgnored private let tilt = TiltController()
    @ObservationIgnored private let encoder = FrameEncoder()
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var scrollVelocity: CGFloat = 0

    /// Fractional word index: words before it have been read.
    @ObservationIgnored private(set) var position: Double = 0
    @ObservationIgnored private var scrollY: CGFloat = 0
    @ObservationIgnored private var pointsScroll: CGFloat = 0
    @ObservationIgnored private var layout: PrompterLayout?
    @ObservationIgnored private var pointsLayoutCache: PointsTextLayout?
    @ObservationIgnored private var geometryKey = ""
    @ObservationIgnored private var level: Float = 0
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var hypCount = 0
    @ObservationIgnored private var commandBase = 0
    @ObservationIgnored private var pending: (match: VoiceCommands.Match, at: CFTimeInterval)?
    @ObservationIgnored private var toast: (text: String, at: CFTimeInterval)?
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var lastTick = CACurrentMediaTime()
    @ObservationIgnored private var lastPiPFrame: CFTimeInterval = 0
    @ObservationIgnored private var lastHeard: CFTimeInterval = 0
    /// Last time the mic picked up anything like a voice (a lower bar than `lastHeard`).
    @ObservationIgnored private var lastVoice: CFTimeInterval = 0
    @ObservationIgnored private var hypCount0 = 0
    /// Where the text scrolls to in Voice mode, in words. It runs a little ahead of the last word
    /// heard while you're talking, since the recognizer reports each word a moment after you say it.
    @ObservationIgnored private var leadPosition: Double = 0
    @ObservationIgnored private var leadBase: Double = 0
    /// Recent word advances (time, word), to measure how fast you talk.
    @ObservationIgnored private var advances: [(t: CFTimeInterval, w: Double)] = []
    @ObservationIgnored private var pipPixelWidth = 1200
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var tiltWasMoving = false
    @ObservationIgnored private var lastTiltStep: CFTimeInterval = 0
    @ObservationIgnored private var started = false

    init(script: Script) {
        title = script.displayTitle
        points = script.pointList
        doc = ScriptDocument(text: script.body)
        spoken = SpokenMarks(count: doc.words.count)
        aligner = SpeechAligner(doc: doc)
        pointTracker = PointTracker(points: script.pointList)
        mode = PrompterSettings.shared.mode
        pointsLayout = script.pointList.isEmpty ? .off : script.pointsLayout
        #if DEBUG
        // Screenshot hook: `-pinned` opens with the talking points pinned.
        if CommandLine.arguments.contains("-pinned"), !script.pointList.isEmpty { pointsLayout = .pinned }
        #endif
        follower.prepare(for: doc, scriptText: script.body)
        wire()
    }

    private func wire() {
        follower.onHypothesis = { [weak self] in self?.handle(hypothesis: $0) }
        follower.onNewUtterance = { [weak self] in
            guard let self else { return }
            self.hypCount = 0
            self.hypCount0 = 0
            self.commandBase = 0
            self.pending = nil
            self.aligner.newUtterance()
            self.pointTracker.newUtterance()
        }
        follower.onLevel = { [weak self] l in
            guard let self else { return }
            // Lights up at once when you speak, settles a little more slowly.
            self.level = l > self.level ? self.level * 0.3 + l * 0.7 : self.level * 0.85 + l * 0.15
            if l > 0.35 { self.lastHeard = CACurrentMediaTime() }
            if l > 0.2 { self.lastVoice = CACurrentMediaTime() }
        }
        follower.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .listening:
                self.listening = true
                self.problem = nil
            case .idle:
                self.listening = false
            case .interrupted:
                self.listening = false
                self.problem = "Mic is busy — reconnecting…"
            case .unavailable(let why):
                self.listening = false
                self.problem = why
            }
            self.dirty = true
        }

        pip.isPaused = { [weak self] in self?.isPaused ?? false }
        pip.overlay.content = { [weak self] in (self?.currentFrame, self?.drawnTurn ?? 0) }
        pip.onSetPlaying = { [weak self] playing in self?.setPaused(!playing) }
        pip.onActiveChanged = { [weak self] active in
            self?.isFloating = active
            self?.dirty = true
        }
        pip.onPossibleChanged = { [weak self] possible in self?.canFloat = possible }
        pip.onRenderSize = { [weak self] size in
            guard let self else { return }
            // Render at the window's real pixel size (within reason) so text stays crisp.
            let screenAspect = self.settings.shape == .landscape ? 1 / self.settings.shape.aspect : self.settings.shape.aspect
            let w = max(Int(size.width), Int(Double(size.height) * screenAspect))
            self.pipPixelWidth = min(1400, max(640, w))
            self.dirty = true
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        pip.setUp()
        UIApplication.shared.isIdleTimerDisabled = true
        updateTilt()

        // On screen: tick in step with the display (up to 120 Hz on ProMotion).
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        // In the background (floating over Camera) the display link stops; this timer takes over.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if CACurrentMediaTime() - self.lastTick > 0.014 { self.tick() }
        }
        t.resume()
        timer = t
        lastTick = CACurrentMediaTime()

        Task { @MainActor in
            let ok = await SpeechFollower.requestPermissions()
            guard self.started else { return }
            if !ok {
                self.problem = "Allow Microphone and Speech Recognition in Settings for voice follow"
                if self.mode == .voice { self.mode = .auto }
            }
            // The mic also keeps the app running in the background, so the floating window stays live.
            self.follower.start(recognize: ok && self.mode == .voice)
        }
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.cancel()
        timer = nil
        displayLink?.invalidate()
        displayLink = nil
        follower.stop()
        tilt.stop()
        pip.tearDown()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Controls

    func float() {
        if isFloating { pip.stop() } else { pip.start() }
    }

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused {
            // Whatever was said while paused must not yank the place around.
            aligner.move(toToken: doc.tokenIndex(forWord: Int(position)), hypothesisCount: hypCount)
            tilt.recenter()
        }
        pip.refreshControls()
        dirty = true
    }

    func restart() { jump(toWord: 0, toast: "Back to top") }

    func backSentence() { run(.backSentence) }

    func nextSentence() { run(.nextSentence) }

    func recenterTilt() {
        tilt.recenter()
        showToast("Tilt level set")
    }

    func nextPoint() { run(.nextPoint) }
    func previousPoint() { run(.previousPoint) }

    /// Finger drag on the preview, in canvas points.
    func drag(by dy: CGFloat) {
        guard let layout else { return }
        dragging = true
        if pointsLayout == .only {
            pointsScroll = max(0, pointsScroll - dy)
        } else {
            scrollY -= dy
            let g = geometry()
            position = min(Double(doc.words.count), max(0, layout.position(forY: scrollY + (g.readingLineY - g.scriptTop) + layout.lineHeight * Self.readingBand / 2)))
        }
        dirty = true
    }

    func endDrag() {
        dragging = false
        aligner.move(toToken: doc.tokenIndex(forWord: Int(position)), hypothesisCount: hypCount)
    }

    // MARK: - Voice

    private func handle(hypothesis hyp: [String]) {
        hypCount = hyp.count

        // Words that turn up while the mic hears nothing like a voice aren't you (the recognizer
        // guessing at noise, or sound from the phone itself). Drop them instead of following them.
        let now = CACurrentMediaTime()
        if now - lastVoice > 2 {
            if hyp.count > hypCount0 {
                CueLog.write("ignored words heard in silence: \(hyp.suffix(hyp.count - hypCount0).joined(separator: " "))")
            }
            hypCount0 = hyp.count
            commandBase = hyp.count
            pending = nil
            aligner.move(toToken: aligner.position, hypothesisCount: hyp.count)
            pointTracker.set(pointTracker.current, hypothesisCount: hyp.count)
            return
        }
        hypCount0 = hyp.count

        if settings.voiceCommands, let m = VoiceCommands.find(in: hyp, from: commandBase) {
            if VoiceCommands.phrase(m.phrase, appearsIn: doc, near: aligner.position) {
                // It's in the script — you're reading it, not commanding.
                commandBase = m.end
                pending = nil
            } else if m.mightGrow {
                if pending?.match.end != m.end || pending?.match.command != m.command {
                    pending = (m, CACurrentMediaTime())
                }
                return
            } else {
                execute(m)
                return
            }
        } else {
            pending = nil
        }

        guard !isPaused, mode == .voice else { return }
        if pointsLayout != .off, pointTracker.update(hypothesis: hyp) {
            currentPoint = pointTracker.current
            dirty = true
        }
        if pointsLayout != .only, aligner.update(hypothesis: hyp) {
            let old = position
            position = Double(aligner.wordPosition)
            follower.updateContext(near: Int(position))
            #if DEBUG
            CueLog.write("follow → word \(Int(position)) after \(hyp.suffix(3).joined(separator: " ")) · level \(String(format: "%.2f", level))")
            #endif
            if position > old && position - old <= 4 {
                advances.append((now, position))
            } else {
                advances.removeAll()
            }
            advances.removeAll { now - $0.t > 5 }
            spoken.clear(from: Int(position))
            for t in aligner.heardTokens { spoken.mark(doc.wordIndex(forToken: t), now: now) }
            dirty = true
        }
    }

    private func execute(_ m: VoiceCommands.Match) {
        pending = nil
        commandBase = m.end
        run(m.command)
        follower.restartTask()
    }

    private func run(_ command: VoiceCommand) {
        let w = min(Int(position), max(0, doc.words.count - 1))
        switch command {
        case .top:
            jump(toWord: 0, toast: command.label)
        case .backLines(let n):
            jump(toWord: lineStart(offset: -n), toast: command.label)
        case .skipLines(let n):
            jump(toWord: lineStart(offset: n), toast: command.label)
        case .backSentence:
            let s = doc.sentenceStart(containing: w)
            jump(toWord: w - s <= 2 ? doc.previousSentenceStart(before: s) : s, toast: command.label)
        case .nextSentence:
            jump(toWord: doc.nextSentenceStart(after: w), toast: command.label)
        case .skipParagraph:
            jump(toWord: doc.nextParagraphStart(after: w), toast: command.label)
        case .nextPoint, .previousPoint:
            guard !points.isEmpty else { return }
            let next = pointTracker.current + (command == .nextPoint ? 1 : -1)
            pointTracker.set(next, hypothesisCount: hypCount)
            currentPoint = pointTracker.current
            showToast(command.label)
        case .pause:
            setPaused(true)
            showToast(command.label)
        case .resume:
            setPaused(false)
            showToast(command.label)
        }
    }

    private func jump(toWord w: Int, toast label: String?) {
        let clamped = min(max(0, w), doc.words.count)
        position = Double(clamped)
        aligner.move(toToken: doc.tokenIndex(forWord: clamped), hypothesisCount: hypCount)
        follower.updateContext(near: clamped)
        if let label { showToast(label) }
        dirty = true
    }

    private func lineStart(offset: Int) -> Int {
        guard let layout, !layout.lines.isEmpty else { return Int(position) }
        let li = layout.lineIndex(forWord: Int(position))
        let target = min(max(0, li + offset), layout.lines.count - 1)
        return layout.lines[target].first
    }

    private func showToast(_ text: String) {
        toast = (text, CACurrentMediaTime())
        dirty = true
    }

    // MARK: - Modes

    private func modeChanged() {
        settings.mode = mode
        follower.setRecognizing(mode == .voice)
        aligner.move(toToken: doc.tokenIndex(forWord: Int(position)), hypothesisCount: hypCount)
        updateTilt()
        dirty = true
    }

    private func updateTilt() {
        let wanted = mode == .tilt || (mode == .voice && settings.tiltInVoice)
        tiltWanted = wanted
        motionForSide = settings.shape == .landscape
        // Landscape also needs motion, to know which way to turn the text.
        if wanted || motionForSide { tilt.start() } else { tilt.stop() }
    }

    private func geometryChanged() {
        geometryKey = ""
        dirty = true
    }

    // MARK: - Frame loop

    private struct Geometry {
        var size: CGSize          // the whole canvas
        var scriptSize: CGSize    // the script area, from the top-left corner
        var pinnedRect: CGRect    // the talking points panel (empty when not pinned)
        var padX: CGFloat
        var scriptTop: CGFloat
        var readingLineY: CGFloat
        var pinnedFont: CGFloat
    }

    private var pinnedFont: CGFloat { max(13, CGFloat(settings.fontSize) * 0.55) }

    /// Pinned talking points: a slim strip under the script, inside the window. The window keeps its
    /// shape — iOS only lets a floating window that shape grow to full width (and tap to enlarge);
    /// a taller one it keeps small.
    private var pinnedStripHeight: CGFloat? {
        guard pointsLayout == .pinned, !points.isEmpty else { return nil }
        return PrompterRenderer.pinnedHeight(count: points.count, fontSize: pinnedFont)
    }

    /// The whole canvas at its nominal size, in text coordinates (before landscape's quarter turn).
    private var nominalCanvasSize: CGSize {
        let w = settings.shape.canvasWidth
        return CGSize(width: w, height: (w / CGFloat(settings.shape.aspect)).rounded())
    }

    /// The floating window's shape at its nominal size, as it sits on screen (landscape is turned).
    private var nominalWindowSize: CGSize {
        let c = nominalCanvasSize
        return settings.shape == .landscape ? CGSize(width: c.height, height: c.width) : c
    }

    private func geometry() -> Geometry {
        var size = nominalCanvasSize
        // Floating: lay the text out at the window's real size, so the text size you picked is the
        // size you read, however big or small you pinch the window. Smaller window, fewer words.
        let win = pip.overlay.bounds.size
        if pip.isActive, win.width >= 120, win.height >= 80 {
            let turned = settings.shape == .landscape
            size = CGSize(width: (turned ? win.height : win.width).rounded(),
                          height: (turned ? win.width : win.height).rounded())
        }
        var scriptSize = size
        var pinnedRect = CGRect.zero
        if let strip = pinnedStripHeight {
            let h = min(strip, size.height * 0.35)
            scriptSize.height = size.height - h
            pinnedRect = CGRect(x: 0, y: scriptSize.height, width: size.width, height: h)
        }
        let H = scriptSize.height
        let lineH = layout?.lineHeight ?? CGFloat(settings.fontSize) * 1.5
        // The line to read sits right at the top, by the camera; the line you just said slides out above it.
        let readingY = 6 + lineH * 0.2 + H * CGFloat(settings.readingLine)
        // Side margins shrink a little on narrow windows so lines keep enough words.
        let padX = min(CGFloat(settings.margin), max(10, scriptSize.width * 0.035))
        return Geometry(size: size, scriptSize: scriptSize, pinnedRect: pinnedRect, padX: padX, scriptTop: 0,
                        readingLineY: min(readingY, H - lineH * 1.5), pinnedFont: pinnedFont)
    }

    private func ensureLayout(_ g: Geometry) {
        let width = g.scriptSize.width - g.padX * 2
        let key = "\(settings.fontSize)|\(width)|\(settings.lineSpacing)|\(pointsLayout.rawValue)|\(settings.shape.rawValue)"
        guard key != geometryKey else { return }
        geometryKey = key
        layout = PrompterLayout(doc: doc, fontSize: CGFloat(settings.fontSize), width: width,
                                lineSpacing: CGFloat(settings.lineSpacing))
        pointsLayoutCache = points.isEmpty ? nil
            : PointsTextLayout(points: points, fontSize: CGFloat(settings.fontSize) * 0.85, width: width - CGFloat(settings.fontSize))
        if let layout {
            scrollY = scrollTarget(layout, geometry())
            scrollVelocity = 0
        }
        dirty = true
    }

    /// The line you're reading sits still on the reading line; the text glides up one line when
    /// you move on to the next. (0 = no drift within a line.)
    static let readingBand: CGFloat = 0

    /// Where the script should be scrolled to. In Voice mode the line you're on stays put at the top
    /// while you say it — no nudge per word — and the text glides up once you reach the next line.
    private func scrollTarget(_ layout: PrompterLayout, _ g: Geometry) -> CGFloat {
        let contentY: CGFloat
        if layout.lines.isEmpty {
            contentY = 0
        } else if mode == .voice && !tiltWasMoving {
            let w = Int(leadPosition)
            contentY = w >= doc.words.count ? layout.contentHeight : layout.lines[layout.lineIndex(forWord: w)].y
        } else {
            contentY = layout.y(forPosition: position)
        }
        return contentY - layout.lineHeight * Self.readingBand / 2 - (g.readingLineY - g.scriptTop)
    }

    /// Runs at your talking pace a little ahead of the last word the recognizer reported (it hears
    /// each word a moment after you say it), so the next line comes up as you finish the last word,
    /// not half a second later. Only the scroll leads: words darken only once they're heard.
    private func updateLead(now: CFTimeInterval, dt: Double) {
        let p = position
        // Moved back (a command, a drag, a re-read), or not following your voice: no lead.
        if p < leadBase || mode != .voice || isPaused || dragging || tiltWasMoving {
            leadBase = p
            leadPosition = p
            return
        }
        leadBase = p
        var rate = 2.5 // words a second, a usual talking pace
        if let a = advances.first, let b = advances.last, b.t - a.t >= 1 {
            rate = min(4.5, max(1.2, (b.w - a.w) / (b.t - a.t)))
        }
        let talking = now - lastHeard < 0.3
        let maxLead = min(1.0, max(0.5, rate * 0.4))
        if talking { leadPosition += rate * dt }
        leadPosition = min(max(leadPosition, p), p + maxLead, Double(doc.words.count))
    }

    func tickFromDisplay() { tick() }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        let g = geometry()
        ensureLayout(g)
        guard let layout else { return }
        let total = Double(doc.words.count)

        tilt.sensitivity = settings.tiltSensitivity
        tilt.reversed = settings.tiltReversed
        // In Voice mode tilt is a deliberate nudge; in Tilt mode it's the main control.
        tilt.deadZone = mode == .tilt ? 5 : 10
        tilt.levelFollow = mode == .tilt ? 0.03 : 0.25
        if settings.mode != mode { mode = settings.mode }
        let tiltOn = mode == .tilt || (mode == .voice && settings.tiltInVoice)
        if tiltOn != tiltWanted || (settings.shape == .landscape) != motionForSide { updateTilt() }
        // Landscape: turn the floating window's text whichever way the phone is on its side.
        let turn = settings.shape == .landscape ? tilt.side : 0
        if turn != drawnTurn { drawnTurn = turn; dirty = true }
        // Keep the floating window visibly live (and quick to recover if the Camera interrupts it).
        if pip.isActive && now - lastPiPFrame > 0.1 { dirty = true }

        // Move the place.
        if !isPaused && !dragging {
            if pointsLayout == .only {
                if tiltOn, abs(tilt.velocity) > 0.45, now - lastTiltStep > 0.9 {
                    lastTiltStep = now
                    run(tilt.velocity > 0 ? .nextPoint : .previousPoint)
                }
            } else {
                switch mode {
                case .auto:
                    position += settings.autoSpeed / 60 * dt
                case .tilt, .voice:
                    if tiltOn && tilt.isActive {
                        position += tilt.velocity * 7 * dt
                        tiltWasMoving = true
                        dirty = true
                    }
                }
                if tiltWasMoving && !tilt.isActive {
                    tiltWasMoving = false
                    aligner.move(toToken: doc.tokenIndex(forWord: Int(position)), hypothesisCount: hypCount)
                }
            }
            position = min(total, max(0, position))
        }

        updateLead(now: now, dt: dt)

        // Which words show as said: everything behind your place. Words the recognizer misheard (an
        // accent, a mumble) dim along with the ones around them once you've said a word after them,
        // so the line fades evenly. Your place only moves on what it heard, so nothing ahead dims.
        let readWord = Int(position)
        spoken.clear(from: readWord)
        spoken.fill(upTo: readWord, now: now)
        if spoken.isFading(now: now) { dirty = true }

        // A command that might still grow ("go back" → "go back two lines"): wait a beat, then do it.
        if let p = pending, now - p.at > 0.7 { execute(p.match) }

        // Glide toward the target.
        // Critically damped spring: no jumps, no overshoot, velocity carries smoothly between moves.
        let k = 1 - exp(-dt * 9)
        let oldScroll = scrollY
        if !dragging {
            let target = scrollTarget(layout, g)
            // The next line glides up gently; bigger moves (skipping, commands) catch up quickly.
            let lag = abs(target - scrollY) / max(1, layout.lineHeight)
            let omega: CGFloat = mode == .voice ? 9 + min(9, max(0, lag - 1) * 5) : 14
            var remaining = CGFloat(dt)
            while remaining > 0 {
                let h = min(remaining, 1.0 / 240.0)
                let accel = omega * omega * (target - scrollY) - 2 * omega * scrollVelocity
                scrollVelocity += accel * h
                scrollY += scrollVelocity * h
                remaining -= h
            }
            if abs(target - scrollY) < 0.05 && abs(scrollVelocity) < 0.5 {
                scrollY = target
                scrollVelocity = 0
            }
        } else {
            scrollVelocity = 0
        }
        if pointsLayout == .only, let pl = pointsLayoutCache, pl.items.indices.contains(currentPoint), !dragging {
            let target = max(0, pl.items[currentPoint].y - (g.size.height * 0.22))
            let old = pointsScroll
            pointsScroll += (target - pointsScroll) * CGFloat(k)
            if abs(pointsScroll - old) > 0.01 { dirty = true }
        }
        if abs(scrollY - oldScroll) > 0.01 { dirty = true }
        if toast != nil { dirty = true }
        // The dot eases to green while it hears your voice and back to grey after a pause, so it
        // doesn't flicker between syllables.
        let voiceOn: Float = now - lastVoice < 0.35 ? 1 : 0
        glow += (voiceOn - glow) * Float(1 - exp(-dt * (voiceOn > glow ? 12 : 4)))
        if listening && abs(glow - drawnLevel) > 0.03 { dirty = true }
        if let t = toast, now - t.at > 1.8 { toast = nil }

        // Lightweight UI state.
        let pct = total > 0 ? Int((position / total * 100).rounded()) : 0
        if pct != progressPercent { progressPercent = pct }
        let isHearing = listening && now - lastHeard < 0.6
        if isHearing != hearing { hearing = isHearing }

        guard dirty else { return }
        dirty = false
        drawnLevel = glow
        let frame = makeFrame(g, layout, now: now)
        currentFrame = frame
        onRedraw?()
        pip.setWindowSize(nominalWindowSize)
        let aspect = Double(nominalCanvasSize.width / nominalCanvasSize.height)
        if abs(aspect - canvasAspect) > 0.001 { canvasAspect = aspect }
        if pip.overlayInstalled { pip.overlay.setNeedsDisplay() }

        // Floating window frames: 60 fps.
        guard pip.usesFrames else { lastPiPFrame = now; return }
        if now - lastPiPFrame >= 1.0 / 62.0 {
            lastPiPFrame = now
            let pxW = pipPixelWidth
            let screen = turn == 0 ? g.size : CGSize(width: g.size.height, height: g.size.width)
            let pxH = Int((Double(pxW) * Double(screen.height) / Double(screen.width)).rounded())
            if let sample = encoder.makeSampleBuffer(pixelWidth: pxW, pixelHeight: pxH, logicalSize: g.size,
                                                     quarterTurn: turn,
                                                     draw: { PrompterRenderer.draw(frame, in: $0) }) {
                pip.enqueue(sample)
            }
        } else {
            dirty = true // make sure the latest state reaches the floating window next tick
        }
    }

    @ObservationIgnored private var tiltWanted = false
    @ObservationIgnored private var motionForSide = false
    @ObservationIgnored private var drawnTurn = 0
    @ObservationIgnored private var drawnLevel: Float = 0
    @ObservationIgnored private var glow: Float = 0
    @ObservationIgnored private(set) var currentFrame: PrompterFrame?

    private func makeFrame(_ g: Geometry, _ layout: PrompterLayout, now: CFTimeInterval) -> PrompterFrame {
        let indicator: PrompterFrame.Indicator
        if problem != nil && mode == .voice {
            indicator = .problem
        } else if isPaused {
            indicator = .paused
        } else {
            switch mode {
            case .voice: indicator = listening ? .listening(glow) : .problem
            case .tilt: indicator = .tilt
            case .auto: indicator = .auto
            }
        }
        var toastText: String? = nil
        var toastAlpha: CGFloat = 0
        if let t = toast {
            let age = now - t.at
            toastText = t.text
            toastAlpha = CGFloat(age < 1.3 ? 1 : max(0, 1 - (age - 1.3) / 0.5))
        }
        let total = Double(max(1, doc.words.count))
        return PrompterFrame(
            size: g.size,
            scriptSize: g.scriptSize,
            pinnedRect: g.pinnedRect,
            doc: doc,
            layout: layout,
            padX: g.padX,
            scriptTop: g.scriptTop,
            scrollY: scrollY,
            spoken: spoken,
            now: now,
            dimSpoken: settings.dimSpoken,
            readingLineY: g.readingLineY,
            pointsLayout: pointsLayout == .only ? pointsLayoutCache : nil,
            pointsScroll: pointsScroll,
            pinnedPoints: pointsLayout == .pinned ? points : [],
            pinnedFontSize: g.pinnedFont,
            currentPoint: currentPoint,
            indicator: indicator,
            progress: pointsLayout == .only ? 0 : position / total,
            toast: toastText,
            toastAlpha: toastAlpha
        )
    }
}

/// Breaks the retain cycle between CADisplayLink and the engine.
private final class DisplayLinkProxy: NSObject {
    weak var engine: PrompterEngine?
    init(_ engine: PrompterEngine) { self.engine = engine }
    @objc func fire() { engine?.displayTick() }
}

extension PrompterEngine {
    fileprivate func displayTick() { tickFromDisplay() }
}
