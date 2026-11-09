import AVFoundation
import CoreMedia
import Speech

/// Low-latency live transcription with Apple's SpeechAnalyzer (iOS 26+).
///
/// Volatile results arrive within a fraction of a second and are refined in place; finalized
/// text accumulates. The hypothesis handed out is finalized + current volatile text.
@available(iOS 26, macOS 26, *)
final class LiveTranscriber {

    /// Full hypothesis since the last reset. Main thread.
    var onTokens: (([String]) -> Void)?
    /// Hypothesis restarted from zero. Main thread.
    var onReset: (() -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var finalized: [String] = []
    private var volatile: [String] = []
    private var latestEnd: CMTime = .zero
    private var ignoreBefore: CMTime = .zero

    /// Sets up the on-device model (downloading it once if needed) and starts listening for audio.
    func start(contextualStrings: [String]) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw NSError(domain: "Cue", code: 2, userInfo: [NSLocalizedDescriptionKey: "English isn't supported"])
        }
        let t = SpeechTranscriber(locale: locale,
                                  transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults],
                                  attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw NSError(domain: "Cue", code: 3)
        }
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let a = SpeechAnalyzer(modules: [t], options: .init(priority: .userInitiated, modelRetention: .processLifetime))

        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await a.setContext(context)
        }

        transcriber = t
        analyzer = a
        lock.withLock {
            continuation = cont
            analyzerFormat = format
            converter = nil
        }

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in t.results {
                    self?.handle(text: String(result.text.characters), range: result.range, isFinal: result.isFinal)
                }
            } catch {}
        }
        try await a.start(inputSequence: stream)
    }

    /// Swap the vocabulary hints while listening (the script words coming up next).
    func setContext(_ strings: [String]) {
        guard let a = analyzer else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        Task { try? await a.setContext(context) }
    }

    /// Called from the audio thread with microphone buffers.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let cont = continuation
        let format = analyzerFormat
        lock.unlock()
        guard let cont, let format else { return }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            cont.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Forget everything heard so far (after a voice command), including words still being refined.
    func reset() {
        ignoreBefore = latestEnd
        finalized = []
        volatile = []
        onReset?()
    }

    func stop() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        analyzerFormat = nil
        lock.unlock()
        resultsTask?.cancel()
        resultsTask = nil
        let a = analyzer
        analyzer = nil
        transcriber = nil
        Task { await a?.cancelAndFinishNow() }
    }

    private func handle(text: String, range: CMTimeRange, isFinal: Bool) {
        if CMTimeCompare(range.end, latestEnd) > 0 { latestEnd = range.end }
        // Audio from before a command was reset away.
        if CMTimeCompare(range.start, ignoreBefore) < 0 { return }
        let tokens = TextNormalizer.tokens(text)
        if isFinal {
            finalized.append(contentsOf: tokens)
            volatile = []
        } else {
            volatile = tokens
        }
        onTokens?(finalized + volatile)
        // Keep the hypothesis short so every update stays instant on long takes.
        if isFinal && finalized.count > 160 {
            finalized = []
            volatile = []
            onReset?()
        }
    }
}
