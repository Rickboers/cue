import SwiftUI
import UIKit

/// Draws the engine's current frame. Drag to scroll, tap to pause.
final class PrompterCanvasView: UIView {
    weak var engine: PrompterEngine?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        layer.drawsAsynchronously = true
        contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let frame = engine?.currentFrame else { return }
        ctx.scaleBy(x: bounds.width / frame.size.width, y: bounds.height / frame.size.height)
        PrompterRenderer.draw(frame, in: ctx)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard let engine, let size = engine.currentFrame?.size, bounds.height > 0 else { return }
        let dy = g.translation(in: self).y * size.height / bounds.height
        g.setTranslation(.zero, in: self)
        switch g.state {
        case .changed: engine.drag(by: dy)
        case .ended, .cancelled, .failed: engine.endDrag()
        default: break
        }
    }

    @objc private func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        engine?.togglePause()
    }
}

/// The prompter preview. The Picture-in-Picture source layer sits right behind it,
/// so floating the prompter zooms out of exactly this card.
struct PrompterCanvas: UIViewRepresentable {
    let engine: PrompterEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let source = engine.pip.sourceView
        source.frame = container.bounds
        source.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(source)

        let canvas = PrompterCanvasView()
        canvas.engine = engine
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(canvas)
        engine.onRedraw = { [weak canvas] in canvas?.setNeedsDisplay() }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
