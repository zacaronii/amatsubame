import AetherBridge
import Core
import Foundation
import PlayerKit

/// Settings ▸ Playback ▸ Engine: which engine plays videos (docs/AETHER_PLAN.md, phase 2). Kept per
/// device in UserDefaults, not in the database: no data tied to the engine, so going back to an
/// mpv-only build loses nothing. It applies when a video opens.
enum EngineChoice: String, CaseIterable, Identifiable {
    case mpv
    case aether

    var id: Self { self }

    var title: String {
        switch self {
        case .mpv: "mpv"
        case .aether: "AetherEngine (beta)"
        }
    }

    static let key = "player.engine"

    static var current: EngineChoice {
        get {
            #if DEBUG
            // UI tests: UITEST_ENGINE=aether runs the player suites on AetherEngine.
            if let forced = ProcessInfo.processInfo.environment["UITEST_ENGINE"].flatMap(EngineChoice.init) { return forced }
            #endif
            return UserDefaults.standard.string(forKey: key).flatMap(EngineChoice.init) ?? .mpv
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// The engine for a video opening now, and a note if AetherEngine couldn't start (mpv plays then).
    @MainActor static func makeEngine() -> (engine: any PlayerEngine, note: String?) {
        guard current == .aether else { return (MPVController(), nil) }
        do {
            return (try AetherPlayerEngine(), nil)
        } catch {
            AppLog.info(.playback, "AetherEngine didn't start (\(error.localizedDescription)); playing with mpv")
            return (MPVController(), "AetherEngine didn't start; playing with mpv")
        }
    }
}
