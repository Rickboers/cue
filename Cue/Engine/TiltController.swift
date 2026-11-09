import CoreMotion
import Foundation

/// Turns tipping the phone into scrolling.
///
/// The angle is measured between the screen and vertical, so it works the same in portrait and
/// landscape. Holding the phone where you started does nothing; tip the top away to scroll
/// forward, toward you to go back. Further tip = faster.
final class TiltController {

    var sensitivity: Double = 1
    var reversed = false
    /// Degrees of tip ignored around level. Bigger in Voice mode so normal hand movement does nothing.
    var deadZone = 5.0
    /// How fast "level" follows slow posture changes (per second). A quick, held tip still scrolls;
    /// slowly changing how you hold the phone doesn't.
    var levelFollow = 0.03

    /// −1...1. Positive scrolls forward.
    private(set) var velocity: Double = 0
    /// Which way the phone is on its side: +1 = top (front camera) to your left, −1 = to your right.
    /// Keeps its last value while upright or flat.
    private(set) var side = 1 {
        didSet { if side != oldValue { CueLog.write("phone on its side, top to your \(side > 0 ? "left" : "right")") } }
    }
    var isActive: Bool { velocity != 0 }

    private let motion = CMMotionManager()
    private var reference: Double?
    private var smoothed: Double = 0
    private let fullTilt = 22.0    // degrees past the dead zone for full speed

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        reference = nil
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            self.update(gravity: g)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        velocity = 0
        reference = nil
    }

    /// Make the current angle the new "still" position.
    func recenter() {
        reference = smoothed
        velocity = 0
    }

    private func update(gravity g: CMAcceleration) {
        // Gravity along the phone's x axis: positive when its right edge points down, i.e. the top
        // is to your right.
        if g.x > 0.6 { side = -1 } else if g.x < -0.6 { side = 1 }
        let planar = sqrt(g.x * g.x + g.y * g.y)
        // 0° = upright, −90° = lying face up, +90° = face down.
        let angle = atan2(g.z, planar) * 180 / .pi
        if reference == nil {
            smoothed = angle
            reference = angle
        }
        smoothed += (angle - smoothed) * 0.25
        guard var ref = reference else { return }
        ref += (smoothed - ref) * min(1, levelFollow / 30)
        reference = ref

        // Tipping the top away makes the screen face up more (angle decreases).
        var delta = ref - smoothed
        if reversed { delta = -delta }
        let mag = abs(delta) - deadZone
        if mag <= 0 {
            velocity = 0
            return
        }
        let x = min(1, mag / fullTilt)
        velocity = (delta > 0 ? 1 : -1) * pow(x, 1.5) * sensitivity
    }
}
