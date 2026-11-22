import Core
import CryptoKit
import Foundation
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif

/// Stats on every device: this app's activity log is kept in the app's iCloud folder (one file a
/// device a month, `StatsSync`), so the same app on another device with the same iCloud account
/// counts it too. Runs when the app comes forward, when it's put away and when Stats opens.
/// Without iCloud (no account, a build without the iCloud entitlement, the simulator) it does nothing.
@Observable
public final class StatsCloudSync {
    public enum State: Equatable {
        case off
        /// Not signed in to iCloud, or this build can't use it.
        case unavailable
        case syncing
        case synced(Date)
        case failed(String)
    }

    static let key = "stats.iCloudSync.off"
    public private(set) var state: State
    /// On unless it's been turned off (Settings ▸ Stats).
    public var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(!isOn, forKey: Self.key)
            state = isOn ? .syncing : .off
            if isOn { Task { await sync(force: true) } }
        }
    }

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastRun = Date.distantPast
    @ObservationIgnored private var running = false

    public init(database: AppDatabase, defaults: UserDefaults = .standard) {
        self.database = database
        self.defaults = defaults
        let on = !defaults.bool(forKey: Self.key)
        isOn = on
        state = on ? .syncing : .off
    }

    /// Sends and fetches. True when the other devices had something new, so Stats should load
    /// again. Passes on a run within the last minute unless `force`d.
    @discardableResult
    public func sync(force: Bool = false) async -> Bool {
        guard isOn, !running, force || Date.now.timeIntervalSince(lastRun) > 60 else { return false }
        // UI tests run on made-up data.
        guard !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("UITEST_") }) else {
            state = .unavailable
            return false
        }
        running = true
        defer { running = false }
        lastRun = .now
        let database = database, hardware = Self.hardware, app = Self.folderName
        let result = await Task.detached(priority: .utility) { Self.run(database: database, hardware: hardware, app: app) }.value
        guard isOn else { return false }
        switch result {
        case nil:
            state = .unavailable
            return false
        case .success(let changed):
            state = .synced(.now)
            if changed { NotificationCenter.default.post(name: .statsDidSync, object: nil) }
            return changed
        case .failure(let error):
            state = .failed(error.localizedDescription)
            return false
        }
    }

    /// When the app is put away: what was just read or heard goes out.
    public func send() {
        Task { await sync(force: true) }
    }

    /// Nil without an iCloud folder. Off the main thread: finding the folder can take a while.
    private nonisolated static func run(database: AppDatabase, hardware: String?, app: String) -> Result<Bool, Error>? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let folder = StatsSyncFolder(url: container.appending(path: "Stats").appending(path: app))
        return Result { try StatsSync(database: database).sync(with: folder, hardware: hardware) }
    }

    /// "yomu", "miru", "kiku": each app's log is its own.
    private static var folderName: String {
        Bundle.main.bundleIdentifier?.split(separator: ".").last.map { $0.lowercased() } ?? "app"
    }

    /// Something that differs between two devices holding copies of the same database (a
    /// restored backup), hashed. Nil when it can't be told.
    private static var hardware: String? {
        #if os(iOS)
        let id = UIDevice.current.identifierForVendor?.uuidString
        #elseif os(macOS)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let id = service == 0 ? nil
            : IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        #else
        let id: String? = nil
        #endif
        return id.map { SHA256.hash(data: Data($0.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
    }
}

public extension Notification.Name {
    /// Another device's activity arrived: Stats and the Today rows count again.
    static let statsDidSync = Notification.Name("statsDidSync")
}
