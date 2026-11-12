import Foundation
import os

/// A small rolling log of what the app did (server errors, sync, dictionary updates, setup),
/// for Settings ▸ Advanced ▸ Export Logs. Kept in a file because iOS's log store only gives
/// back the current launch. Tokens, keys and passwords are blanked before anything is written.
/// Nothing leaves the device unless the user shares the export.
public enum AppLog {
    public enum Area: String, Sendable {
        case servers, sync, dictionaries, setup, downloads, app
    }

    /// Two files of this size at most: the current one and the one before.
    static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "AppLog")
    nonisolated(unsafe) private static var folderOverride: URL?

    /// Application Support/Logs, or a test folder.
    public static var folder: URL {
        folderOverride ?? URL.applicationSupportDirectory.appending(path: "Logs", directoryHint: .isDirectory)
    }

    static var current: URL { folder.appending(path: "app.log") }
    static var previous: URL { folder.appending(path: "app.1.log") }

    /// For tests: log into `folder` instead.
    public static func useFolder(_ folder: URL?) {
        queue.sync { folderOverride = folder }
    }

    public static func info(_ area: Area, _ message: String) { write(area, "", message) }
    public static func error(_ area: Area, _ message: String) { write(area, "error: ", message) }

    private static func write(_ area: Area, _ level: String, _ message: String) {
        let text = redacted(message)
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Amatsubame", category: area.rawValue)
            .log("\(level, privacy: .public)\(text, privacy: .public)")
        let line = "\(Date().formatted(.iso8601)) [\(area.rawValue)] \(level)\(text)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let size = (try? manager.attributesOfItem(atPath: current.path(percentEncoded: false))[.size] as? Int) ?? 0
            if size + line.utf8.count > maxBytes {
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: current, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: current) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: current)
            }
        }
    }

    /// Both files, oldest first, plus any `extra` files (the debug logs), as one text file for
    /// sharing. Returns its location in the temporary folder.
    public static func export(appName: String, extra: [URL] = []) -> URL? {
        queue.sync {
            var text = "\(appName) log, exported \(Date().formatted(.iso8601))\n\n"
            for file in [previous, current] + extra {
                guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if extra.contains(file) { text += "\n--- \(file.lastPathComponent) ---\n" }
                text += redacted(contents)
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "\(appName) Log.txt")
            return (try? Data(text.utf8).write(to: url)).map { url }
        }
    }

    /// Blanks secrets: values after key-, token- and password-like names (in URLs, headers and
    /// JSON), bearer tokens, and long runs of hex or base64 that are probably keys.
    public static func redacted(_ text: String) -> String {
        var text = text
        let patterns = [
            #"(?i)(bearer\s+|mediabrowser\s+token=")([^\s",]+)"#,
            #"(?i)(api[_-]?key|apikey|token|access[_-]?token|password|passwd|secret|auth(?:orization)?|x-emby-token|key)(["']?\s*[:=]\s*["']?)([^\s"'&,;})\]]+)"#,
            #"\b[A-Fa-f0-9]{24,}\b"#,
            #"[A-Za-z0-9+_-]{32,}={0,2}"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let template = switch index {
            case 0: "$1•••"
            case 1: "$1$2•••"
            default: "•••"
            }
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return text
    }
}
