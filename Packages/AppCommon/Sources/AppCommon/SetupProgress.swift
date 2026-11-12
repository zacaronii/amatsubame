import Foundation
import Observation

/// Where this app's first-launch setup stands, kept per app. Setup
/// shows until it's finished or skipped; leaving mid-way resumes at the same step.
@Observable
public final class SetupProgress {
    public enum Status: String, Sendable {
        case notStarted, inProgress, finished, skipped
    }

    public private(set) var status: Status
    /// The step to resume at (a `SetupStep` raw value).
    public private(set) var step: String?
    /// Run Setup Again: shown right away, even though the app is set up.
    public private(set) var isRerun = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "firstLaunchSetup") {
        self.defaults = defaults
        self.key = key
        status = defaults.string(forKey: "\(key).status").flatMap(Status.init) ?? .notStarted
        step = defaults.string(forKey: "\(key).step")
    }

    /// Whether setup should be on screen.
    public var showsSetup: Bool { status == .notStarted || status == .inProgress }

    /// At launch: an install that's already set up (its server connected) never sees setup.
    /// Only while setup hasn't started, so Run Setup Again isn't undone on the next launch.
    public func noteExistingSetup(hasServer: Bool) {
        guard status == .notStarted, hasServer else { return }
        save(.finished, step: nil)
    }

    public func reached(_ step: String) {
        save(.inProgress, step: step)
    }

    public func finish() {
        isRerun = false
        save(.finished, step: nil)
    }

    public func skip() {
        isRerun = false
        save(.skipped, step: nil)
    }

    /// Settings ▸ Advanced ▸ Run Setup Again: from the start; nothing is deleted.
    public func runAgain() {
        isRerun = true
        save(.inProgress, step: nil)
    }

    /// For UI tests: setup as on a first launch.
    public func reset() {
        isRerun = false
        save(.notStarted, step: nil)
    }

    private func save(_ status: Status, step: String?) {
        self.status = status
        self.step = step
        defaults.set(status.rawValue, forKey: "\(key).status")
        defaults.set(step, forKey: "\(key).step")
    }
}
