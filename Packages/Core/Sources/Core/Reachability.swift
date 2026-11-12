import Foundation
import Network
import Observation

/// Publishes whether the device has a usable network path and calls `onBecameOnline` on each
/// offline → online transition, or a switch to another network while online (Wi-Fi to cellular,
/// a VPN like Tailscale connecting): servers that failed may be reachable now.
@MainActor @Observable
public final class Reachability {
    public private(set) var isOnline = true
    /// On cellular or a hotspot (or Low Data Mode), where downloads wait unless allowed.
    public private(set) var isExpensive = false
    /// Counts the times the device came online or switched networks, for views to retry on.
    public private(set) var reconnections = 0
    @ObservationIgnored public var onBecameOnline: (@MainActor () -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// The interfaces of the last path (nil before the first).
    @ObservationIgnored private var interfaces: [String]?

    public init() {}

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor in
                self?.isExpensive = expensive
                self?.update(online, interfaces: interfaces)
            }
        }
        monitor.start(queue: DispatchQueue(label: "Reachability"))
    }

    private func update(_ online: Bool, interfaces: [String]) {
        let wasOnline = isOnline
        let switched = self.interfaces.map { $0 != interfaces } ?? false
        isOnline = online
        self.interfaces = interfaces
        if online && (!wasOnline || switched) {
            reconnections += 1
            onBecameOnline?()
        }
    }

    deinit {
        monitor.cancel()
    }
}
