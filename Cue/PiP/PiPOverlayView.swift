import UIKit

/// The live prompter, drawn by Cue itself inside the floating window.
///
/// While the Camera app is open, iOS stops showing video in floating windows (it goes black with a
/// crossed-out play button). This view sits on top of that video inside the floating window and is
/// drawn like any other view, so the script stays live over the Camera.
final class PiPOverlayView: UIView {
    /// The frame to show and how far to turn it (+1 / −1 quarter turn for landscape recording).
    var content: () -> (frame: PrompterFrame?, quarterTurn: Int) = { (nil, 0) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        contentMode = .redraw
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let (f, turn) = content()
        guard let f else { return }
        let screen = turn == 0 ? f.size : CGSize(width: f.size.height, height: f.size.width)
        // Fit the frame into the window (they share a shape, so this fills it).
        let s = min(bounds.width / screen.width, bounds.height / screen.height)
        ctx.translateBy(x: (bounds.width - screen.width * s) / 2, y: (bounds.height - screen.height * s) / 2)
        ctx.scaleBy(x: s, y: s)
        if turn > 0 {
            ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: screen.width, ty: 0))
        } else if turn < 0 {
            ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: screen.height))
        }
        PrompterRenderer.draw(f, in: ctx)

        // Diary: how often the floating window actually redraws, every 5 s.
        draws += 1
        let now = CACurrentMediaTime()
        if now - lastReport >= 5 {
            let state = UIApplication.shared.applicationState == .background ? "background" : "foreground"
            CueLog.write("floating: \(draws) redraws in \(Int(now - lastReport)) s, app \(state), \(Int(bounds.width))×\(Int(bounds.height))")
            draws = 0
            lastReport = now
        }
    }

    private var draws = 0
    private var lastReport: CFTimeInterval = 0
}
