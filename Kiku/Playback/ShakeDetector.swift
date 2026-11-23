#if os(iOS)
import CoreMotion
import Foundation

/// A shake of the phone, from the accelerometer, so it's felt with the screen off too (the app
/// keeps running while it plays). Only on while the sleep timer could use it.
final class ShakeDetector {
    private let motion = CMMotionManager()
    private var peaks: [Date] = []
    private var lastShake = Date.distantPast

    func start(_ onShake: @escaping @MainActor () -> Void) {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        peaks = []
        motion.accelerometerUpdateInterval = 0.05
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                if self.registers(data.acceleration, at: .now) { onShake() }
            }
        }
    }

    func stop() {
        guard motion.isAccelerometerActive else { return }
        motion.stopAccelerometerUpdates()
    }

    /// Three jolts well over gravity within a second: a shake, not turning over in bed or
    /// putting the phone down. Then nothing for two seconds.
    private func registers(_ acceleration: CMAcceleration, at now: Date) -> Bool {
        let g = (acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z).squareRoot()
        guard abs(g - 1) > 1.3 else { return false }
        if let last = peaks.last, now.timeIntervalSince(last) < 0.12 { return false }
        peaks = peaks.filter { now.timeIntervalSince($0) < 1 } + [now]
        guard peaks.count >= 3, now.timeIntervalSince(lastShake) > 2 else { return false }
        peaks = []
        lastShake = now
        return true
    }
}
#endif
