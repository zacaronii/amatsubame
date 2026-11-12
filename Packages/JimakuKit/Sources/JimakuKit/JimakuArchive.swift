import Foundation
import ZIPFoundation

/// What a Jimaku file is: a subtitle the app can read, a zip of them, or something it can't open.
public enum JimakuFileKind: Equatable, Sendable {
    case subtitle, zip
    case unsupported(String)

    public init(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "srt", "ass", "ssa": self = .subtitle
        case "zip": self = .zip
        case let other: self = .unsupported(other.isEmpty ? "this" : ".\(other)")
        }
    }
}

/// The subtitle files inside a zip from Jimaku (often a whole season).
public enum JimakuArchive {
    public struct Member: Hashable, Sendable, Identifiable {
        public var name: String
        public var data: Data
        public var id: String { name }
    }

    public static func subtitles(in zip: Data) throws -> [Member] {
        let archive = try Archive(data: zip, accessMode: .read)
        var members: [Member] = []
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent
            guard !name.hasPrefix("."), JimakuFileKind(fileName: name) == .subtitle else { continue }
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            members.append(Member(name: name, data: data))
        }
        return members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
