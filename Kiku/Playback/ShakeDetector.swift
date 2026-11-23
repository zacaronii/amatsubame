import Foundation

/// Three jolts well over gravity within a second: a shake, not turning over in bed or putting the
/// phone down. Then nothing for two seconds. (Its own type, with the time passed in, for tests.)
struct ShakePattern {
    private var peaks: [Date] = []
    private var lastShake = Date.distantPast

    /// One accelerometer reading, its size in g (1 at rest).
    mutating func registers(g: Double, at now: Date) -> Bool {
        guard abs(g - 1) > 1.3 else { return false }
        // One jolt read over several samples counts once.
        if let last = peaks.last, now.timeIntervalSince(last) < 0.12 { return false }
        peaks = peaks.filter { now.timeIntervalSince($0) < 1 } + [now]
        guard peaks.count >= 3, now.timeIntervalSince(lastShake) > 2 else { return false }
        peaks = []
        lastShake = now
        return true
    }
}

#if os(iOS)
import CoreMotion

/// A shake of the phone, from the accelerometer, so it's felt with the screen off too (the app
/// keeps running while it plays). Only on while the sleep timer could use it.
final class ShakeDetector {
    private let motion = CMMotionManager()
    private var pattern = ShakePattern()

    func start(_ onShake: @escaping @MainActor () -> Void) {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        pattern = ShakePattern()
        motion.accelerometerUpdateInterval = 0.05
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                let a = data.acceleration
                if self.pattern.registers(g: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot(), at: .now) { onShake() }
            }
        }
    }

    func stop() {
        guard motion.isAccelerometerActive else { return }
        motion.stopAccelerometerUpdates()
    }
}
#endif
