import AVFoundation
import Speech

/// Listens to the microphone and streams live English transcripts.
///
/// - Recognition runs on device, so it is private and has no one-minute limit; tasks are still
///   recycled during pauses to keep partial results short and fast.
/// - A custom language model is trained on the script, so names and jargon in it are recognized.
/// - Interruptions (another app grabbing the mic, route changes) are recovered from automatically.
final class SpeechFollower {

    enum Status: Equatable {
        case idle
        case listening
        case interrupted
        case unavailable(String)
    }

    /// Full normalized hypothesis of the current recognition task. Main thread.
    var onHypothesis: (([String]) -> Void)?
    /// A new recognition task began; hypotheses restart from zero. Main thread.
    var onNewUtterance: (() -> Void)?
    /// Input level 0...1, roughly 20 times a second. Main thread.
    var onLevel: ((Float) -> Void)?
    var onStatus: ((Status) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    private var running = false
    private var recognizing = false
    private var taskStarted = Date()
    private var lastResultAt = Date()
    private var lastTokenCount = 0
    private var housekeeping: Timer?
    private var observers: [NSObjectProtocol] = []
    private var levelAccumulator: (sum: Float, count: Int) = (0, 0)

    private var contextualStrings: [String] = []
    private var globalContext: [String] = []
    private weak var doc: ScriptDocument?
    private var contextWord = 0

    /// Point the recognizer's hints at the words just ahead of `word` (call as you read on).
    func updateContext(near word: Int) {
        guard let doc, abs(word - contextWord) >= 15 else { return }
        contextWord = word
        contextualStrings = globalContext + doc.upcomingContext(from: word)
        lock.lock()
        let l = live
        lock.unlock()
        if #available(iOS 26, macOS 26, *), let l = l as? LiveTranscriber { l.setContext(contextualStrings) }
    }
    /// LiveTranscriber (iOS 26+). Guarded by `lock` because the audio thread feeds it.
    private var live: AnyObject?
    private var liveFailed = false
    private var languageModel: AnyObject? // SFSpeechLanguageModel.Configuration (iOS 17+)
    private var modelKey = ""

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    // MARK: - Permissions

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    // MARK: - Script context

    /// Feed vocabulary hints and train a script-specific language model in the background.
    func prepare(for doc: ScriptDocument, scriptText: String) {
        self.doc = doc
        contextWord = 0
        globalContext = doc.distinctiveWords(limit: 40)
        contextualStrings = globalContext + doc.upcomingContext(from: 0)
        let sentences = doc.sentences(limit: 1500)
        guard !sentences.isEmpty else { return }
        var hasher = Hasher()
        hasher.combine(scriptText)
        let key = String(UInt(bitPattern: hasher.finalize()), radix: 36)
        guard key != modelKey else { return }
        modelKey = key
        languageModel = nil
        if #available(iOS 17, macOS 14, *) {
            Task { @MainActor [weak self] in
                // Training runs off the main thread inside the static async function.
                let config = await Self.buildLanguageModel(sentences: sentences, key: key)
                guard let self, self.modelKey == key, let config else { return }
                self.languageModel = config
                // Pick it up on the next pause.
                if self.recognizing { self.restartWhenQuiet = true }
            }
        }
    }

    private var restartWhenQuiet = false

    @available(iOS 17, macOS 14, *)
    private static func buildLanguageModel(sentences: [String], key: String) async -> SFSpeechLanguageModel.Configuration? {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CueLM", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dataURL = dir.appendingPathComponent("\(key).bin")
        let lmURL = dir.appendingPathComponent("\(key).lm")
        let vocabURL = dir.appendingPathComponent("\(key).vocab")
        let config = SFSpeechLanguageModel.Configuration(languageModel: lmURL, vocabulary: vocabURL)
        if fm.fileExists(atPath: lmURL.path) { return config }

        // Keep only the most recent few models around.
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
           old.count > 18 {
            let sorted = old.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            for u in sorted.prefix(old.count - 12) { try? fm.removeItem(at: u) }
        }

        let data = SFCustomLanguageModelData(locale: Locale(identifier: "en-US"),
                                             identifier: (Bundle.main.bundleIdentifier ?? "cue") + ".script",
                                             version: key)
        for s in sentences {
            data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: s, count: 40))
        }
        do {
            try await data.export(to: dataURL)
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: dataURL,
                                                                      clientIdentifier: Bundle.main.bundleIdentifier ?? "cue",
                                                                      configuration: config)
            return config
        } catch {
            return nil
        }
    }

    // MARK: - Running

    /// Start the microphone. With `recognize == false` the mic only drives the level meter
    /// (which also keeps the app alive in the background while the prompter floats).
    func start(recognize: Bool) {
        recognizing = recognize
        if running {
            if recognize && task == nil { startTask() }
            if !recognize { stopTask() }
            return
        }
        do {
            try configureSession()
            startKeepAlive()
            try startEngine()
            running = true
            status = .listening
            observeSystem()
            if recognize { startTask() }
            housekeeping = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.tickHousekeeping()
            }
        } catch {
            CueLog.write("mic start failed: \(error)")
            status = .unavailable("Microphone unavailable")
        }
    }

    func setRecognizing(_ on: Bool) {
        guard on != recognizing else { return }
        recognizing = on
        if on { startTask() } else { stopTask() }
    }

    func stop() {
        housekeeping?.invalidate()
        housekeeping = nil
        stopTask()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        keepAlive?.stop()
        keepAlive = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        running = false
        status = .idle
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Throw away the current transcript and start fresh (after a voice command).
    func restartTask() {
        guard running, recognizing else { return }
        if #available(iOS 26, macOS 26, *), let l = live as? LiveTranscriber {
            l.reset()
            return
        }
        stopTask()
        startTask()
    }

    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Mix with others so the Camera app (or music) can keep using audio while we listen.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        // Small audio chunks: each word reaches the recognizer sooner.
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        #endif
    }

    // MARK: Staying alive

    /// Silence on a loop, separate from the mic. While Cue floats over the Camera app, the Camera
    /// takes the microphone and our mic engine stops; without some audio still running, iOS freezes
    /// Cue within seconds and the floating window stops updating. This keeps it going regardless.
    private var keepAlive: AVAudioPlayer?

    private func startKeepAlive() {
        if let p = keepAlive {
            if !p.isPlaying { p.play() }
            return
        }
        guard let p = try? AVAudioPlayer(data: Self.silence(seconds: 2)) else { return }
        p.numberOfLoops = -1
        p.prepareToPlay()
        p.play()
        keepAlive = p
    }

    /// A short silent 16-bit mono WAV.
    private static func silence(seconds: Double) -> Data {
        let rate: UInt32 = 8000
        let samples = UInt32(Double(rate) * seconds)
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + samples * 2)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(rate); put32(rate * 2); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(samples * 2)
        d.append(Data(count: Int(samples * 2)))
        return d
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Cue", code: 1)
        }
        input.removeTap(onBus: 0)
        if let old = sink {
            engine.disconnectNodeInput(old)
            engine.detach(old)
            sink = nil
        }
        loggedChunk = false
        // A tap only hands over audio 100 ms at a time. A sink gets it as it arrives; pass it on in
        // 20 ms chunks so each word reaches the recognizer sooner.
        if format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
           let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) {
            let s = makeSink(mono: mono, chunk: AVAudioFrameCount(format.sampleRate * 0.02))
            engine.attach(s)
            engine.connect(input, to: s, format: format)
            engine.prepare()
            do {
                try engine.start()
                sink = s
                return
            } catch {
                CueLog.write("mic sink failed: \(error) — using a tap")
                engine.disconnectNodeInput(s)
                engine.detach(s)
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private var sink: AVAudioSinkNode?
    private let micQueue = DispatchQueue(label: "cue.mic", qos: .userInteractive)

    /// Collects the mic's first channel into `chunk`-sized buffers, then hands each one off the audio thread.
    private func makeSink(mono: AVAudioFormat, chunk: AVAudioFrameCount) -> AVAudioSinkNode {
        var pending: AVAudioPCMBuffer?
        let queue = micQueue
        return AVAudioSinkNode { [weak self] _, frames, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let src = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frames)
            var offset = 0
            while offset < n {
                if pending == nil { pending = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunk) }
                guard let p = pending, let dst = p.floatChannelData?[0] else { return noErr }
                let take = min(n - offset, Int(chunk - p.frameLength))
                (dst + Int(p.frameLength)).update(from: src + offset, count: take)
                p.frameLength += AVAudioFrameCount(take)
                offset += take
                if p.frameLength == chunk {
                    pending = nil
                    queue.async { self?.consume(p) }
                }
            }
            return noErr
        }
    }

    private var loggedChunk = false

    private func consume(_ buffer: AVAudioPCMBuffer) {
        if !loggedChunk {
            loggedChunk = true
            let ms = Int(Double(buffer.frameLength) / buffer.format.sampleRate * 1000)
            DispatchQueue.main.async { CueLog.write("mic chunks: \(ms) ms") }
        }
        lock.lock()
        let req = request
        let liveRecognizer = live
        lock.unlock()
        if #available(iOS 26, macOS 26, *), let l = liveRecognizer as? LiveTranscriber {
            l.append(buffer)
        } else {
            req?.append(buffer)
        }

        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float((n + 3) / 4))
        // Map roughly -55 dB...-10 dB to 0...1.
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(1, max(0, (db + 55) / 45))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    private func startTask() {
        if #available(iOS 26, macOS 26, *), !liveFailed {
            startLive()
            return
        }
        startLegacyTask()
    }

    @available(iOS 26, macOS 26, *)
    private func startLive() {
        guard live == nil else { return }
        let l = LiveTranscriber()
        l.onTokens = { [weak self] tokens in
            guard let self, self.running, self.recognizing else { return }
            self.lastResultAt = Date()
            self.onHypothesis?(tokens)
        }
        l.onReset = { [weak self] in self?.onNewUtterance?() }
        lock.lock()
        live = l
        lock.unlock()
        onNewUtterance?()
        if status != .listening { status = .listening }
        let words = contextualStrings
        Task { @MainActor [weak self] in
            do {
                try await l.start(contextualStrings: words)
            } catch {
                // Fall back to the classic recognizer.
                guard let self else { return }
                self.lock.withLock {
                    if self.live === l { self.live = nil }
                }
                l.stop()
                self.liveFailed = true
                if self.running && self.recognizing { self.startLegacyTask() }
            }
        }
    }

    private func startLegacyTask() {
        guard let recognizer else {
            status = .unavailable("English speech recognition isn't available")
            return
        }
        guard recognizer.isAvailable else {
            status = .unavailable("Speech recognition is unavailable right now")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        // Audio must never leave the phone, so only on-device recognition is allowed.
        guard recognizer.supportsOnDeviceRecognition else {
            status = .unavailable("This iPhone can't recognize speech on the device")
            return
        }
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = contextualStrings
        if #available(iOS 17, macOS 14, *), let lm = languageModel as? SFSpeechLanguageModel.Configuration {
            req.customizedLanguageModel = lm
        }
        lock.lock()
        request = req
        lock.unlock()

        generation += 1
        let gen = generation
        taskStarted = Date()
        lastResultAt = Date()
        lastTokenCount = 0
        restartWhenQuiet = false
        onNewUtterance?()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                self?.handle(text: text, isFinal: isFinal, error: error, generation: gen)
            }
        }
        if status != .listening { status = .listening }
    }

    private func stopTask() {
        lock.lock()
        let req = request
        request = nil
        let liveRecognizer = live
        live = nil
        lock.unlock()
        if #available(iOS 26, macOS 26, *), let l = liveRecognizer as? LiveTranscriber { l.stop() }
        req?.endAudio()
        task?.cancel()
        task = nil
        generation += 1
    }

    private func handle(text: String?, isFinal: Bool, error: Error?, generation gen: Int) {
        guard gen == generation, running, recognizing else { return }
        if let text {
            let tokens = TextNormalizer.tokens(text)
            if tokens.count != lastTokenCount { lastResultAt = Date() }
            lastTokenCount = tokens.count
            onHypothesis?(tokens)
        }
        if isFinal || error != nil {
            // The recognizer ended this task (silence, error, or its own limit). Keep listening.
            stopTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + (error != nil && text == nil ? 0.4 : 0.05)) { [weak self] in
                guard let self, self.running, self.recognizing, self.task == nil else { return }
                self.startTask()
            }
        }
    }

    private func tickHousekeeping() {
        guard running else { return }
        startKeepAlive()
        // The Camera app took the mic (or a call did): keep asking for it back.
        if !engine.isRunning {
            if now() - lastMicRetry > 1 {
                lastMicRetry = now()
                recover()
            }
            return
        }
        guard recognizing else { return }
        if live != nil { return } // the live transcriber handles long sessions itself
        if task == nil { startTask(); return }
        let age = Date().timeIntervalSince(taskStarted)
        let quiet = Date().timeIntervalSince(lastResultAt)
        // Recycle the task during a natural pause so long sessions stay fast.
        if (quiet > 0.9 && (age > 45 || lastTokenCount > 160 || restartWhenQuiet)) || age > 110 {
            stopTask()
            startTask()
        }
    }

    private func observeSystem() {
        #if os(iOS)
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "-"
            CueLog.write("audio interruption \(type == .began ? "began" : "ended") reason \(reason) engine \(self.engine.isRunning)")
            if type == .began {
                self.status = .interrupted
            } else {
                self.startKeepAlive()
                self.recover()
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            self?.recover()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).map(String.init) ?? "-"
            CueLog.write("route change reason \(reason) engine \(self.engine.isRunning)")
            guard self.running, !self.engine.isRunning else { return }
            self.recover()
        })
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            CueLog.write("engine configuration change, running \(self?.engine.isRunning ?? false)")
            self?.recover()
        })
    }

    private var lastMicRetry: Double = 0
    private func now() -> Double { Date().timeIntervalSinceReferenceDate }

    /// Get the mic back after something took it. Never stops a mic that's still working.
    private func recover() {
        guard running else { return }
        startKeepAlive()
        if engine.isRunning {
            if status != .listening { status = .listening }
            return
        }
        do {
            try configureSession()
            try startEngine()
            if recognizing { stopTask(); startTask() }
            status = .listening
            CueLog.write("mic back")
        } catch {
            if status != .interrupted { CueLog.write("mic still busy: \(error)") }
            status = .interrupted
        }
    }
}
