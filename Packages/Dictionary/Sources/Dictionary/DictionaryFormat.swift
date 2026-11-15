import Foundation

/// The format of an imported dictionary folder: hoshidicts marks it with an empty
/// `.hoshidicts_<N>` file. A folder copied from a Hachidori host carries the host
/// engine's marker, which can be newer than this app's engine reads.
public enum DictionaryFormat: Equatable, Sendable {
    /// The newest marker the vendored engine reads (src/query.cpp). scripts/update-hoshidicts.sh
    /// checks it after each engine update.
    public static let newest = 6

    case supported(Int)
    /// Written by a newer engine: the app needs updating before it can load it.
    case newer(Int)
    /// No marker: not an imported dictionary, or an import that didn't finish.
    case missing

    public init(folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let versions = names.compactMap { name -> Int? in
            guard name.hasPrefix(".hoshidicts_") else { return nil }
            return Int(name.dropFirst(".hoshidicts_".count))
        }
        guard let version = versions.max() else {
            self = .missing
            return
        }
        self = version > Self.newest ? .newer(version) : .supported(version)
    }

    /// Why the engine can't load the folder, or nil when it should.
    public var problem: String? {
        switch self {
        case .supported: nil
        case .newer: "Made by a newer version of hoshidicts. Update the app to use it."
        case .missing: "Couldn't be loaded. Try deleting and re-importing it."
        }
    }
}
