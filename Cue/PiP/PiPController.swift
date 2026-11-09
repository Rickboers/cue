import AVKit
import QuartzCore
import UIKit

/// The view that hosts the sample-buffer layer Picture in Picture lifts out of the app.
final class PiPSourceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Floats the prompter over other apps (the Camera app) using system Picture in Picture.
///
/// It uses the "video call" kind of floating window: its content is an ordinary view Cue draws,
/// not a video. iOS stops video floating windows while the Camera app records (black, with a
/// crossed-out play button), but a call window keeps showing — that's how the text stays live.
final class PiPController: NSObject {

    let sourceView = PiPSourceView()
    /// Cue's live prompter view, shown inside the floating window.
    let overlay = PiPOverlayView()
    private let callView = AVPictureInPictureVideoCallViewController()
    /// The call window draws `overlay` itself; video frames are only needed for the old video window.
    let usesFrames = false
    var overlayInstalled: Bool { isActive }

    var isPaused: () -> Bool = { false }
    var onSetPlaying: ((Bool) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?
    var onPossibleChanged: ((Bool) -> Void)?
    /// Size of the PiP window in pixels, so frames can be rendered crisp.
    var onRenderSize: ((CMVideoDimensions) -> Void)?

    private(set) var isActive = false
    private(set) var isPossible = false
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var backgroundObserver: NSObjectProtocol?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func setUp() {
        guard controller == nil, Self.isSupported else { return }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            // Opening the Camera app right after floating makes iOS pause us; that isn't you.
            self?.ignorePausesUntil = CACurrentMediaTime() + 3
        }
        overlay.frame = callView.view.bounds
        callView.view.backgroundColor = .black
        callView.view.addSubview(overlay)
        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: sourceView,
                                                                contentViewController: callView)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        // Swiping home while the prompter is open floats it automatically.
        c.canStartPictureInPictureAutomaticallyFromInline = true
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            DispatchQueue.main.async {
                self?.isPossible = c.isPictureInPicturePossible
                self?.onPossibleChanged?(c.isPictureInPicturePossible)
            }
        }
    }

    /// The floating window's shape, in points as it appears on screen.
    func setWindowSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, callView.preferredContentSize != size else { return }
        callView.preferredContentSize = size
        overlay.setNeedsDisplay()
    }

    func tearDown() {
        controller?.stopPictureInPicture()
        possibleObservation = nil
        controller = nil
        sourceView.displayLayer.sampleBufferRenderer.flush()
    }

    private var lastDimensions: CMVideoDimensions?

    func enqueue(_ sample: CMSampleBuffer) {
        let renderer = sourceView.displayLayer.sampleBufferRenderer
        // Switching between landscape and upright changes the frame size; start the stream fresh.
        var sizeChanged = false
        if let desc = CMSampleBufferGetFormatDescription(sample) {
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            sizeChanged = lastDimensions.map { $0.width != dims.width || $0.height != dims.height } ?? false
            lastDimensions = dims
        }
        if renderer.status == .failed {
            CueLog.write("floating window renderer failed: \(renderer.error.map { "\($0)" } ?? "-")")
        }
        if sizeChanged || renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sample)

        // Diary: how many frames actually reach the floating window, every 5 s while it's up.
        framesSent += 1
        let now = CACurrentMediaTime()
        if isActive, now - lastReport >= 5 {
            let state = UIApplication.shared.applicationState == .background ? "background" : "foreground"
            CueLog.write("floating: \(framesSent) frames in \(Int(now - lastReport)) s, app \(state)")
            framesSent = 0
            lastReport = now
        }
    }

    private var framesSent = 0
    private var lastReport: CFTimeInterval = 0

    // MARK: Play / pause from the floating window

    /// Don't treat pauses as yours until this time (set when Cue goes to the background).
    var ignorePausesUntil: CFTimeInterval = 0
    private var lastPauseRequest: CFTimeInterval = 0
    private var pendingPause: DispatchWorkItem?

    /// iOS pauses the floating window by itself when the Camera app opens: two pause requests in the
    /// same instant, right as Cue goes to the background. A real tap sends one. Those system pauses are
    /// ignored (the window keeps running); a pause you tap is applied a moment later.
    private func handleSetPlaying(_ playing: Bool) {
        let now = CACurrentMediaTime()
        if playing {
            pendingPause?.cancel()
            pendingPause = nil
            CueLog.write("floating window: play")
            onSetPlaying?(true)
            refreshControls()
            return
        }
        let burst = now - lastPauseRequest < 0.2
        lastPauseRequest = now
        if burst || now < ignorePausesUntil {
            pendingPause?.cancel()
            pendingPause = nil
            CueLog.write("floating window: ignored a pause from iOS")
            refreshControls()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPause = nil
            CueLog.write("floating window: pause")
            self.onSetPlaying?(false)
            self.refreshControls()
        }
        pendingPause = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func start() {
        guard let controller, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    /// Call after pausing/resuming so the play button in the floating window updates.
    func refreshControls() {
        controller?.invalidatePlaybackState()
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        CueLog.write("floating window started")
        ignorePausesUntil = CACurrentMediaTime() + 3
        lastReport = CACurrentMediaTime()
        framesSent = 0
        isActive = true
        overlay.setNeedsDisplay()
        onActiveChanged?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        CueLog.write("floating window stopped")
        isActive = false
        onActiveChanged?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        CueLog.write("floating window failed to start: \(error)")
        isActive = false
        onActiveChanged?(false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async { [weak self] in self?.handleSetPlaying(playing) }
    }

    /// Live content: no scrubber, just play / pause.
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        isPaused()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        onRenderSize?(newRenderSize)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
