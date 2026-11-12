#if DEBUG
import AudiobookshelfKit
import Core
import Foundation

/// A simulator set up for hands-on testing, handed in once at launch through the environment
/// (`xcrun simctl launch` with `SIMCTL_CHILD_DEV_SETUP=1` and the `DEV_…` values), so nothing
/// is typed into the app or written in the code. Servers sign in through the same models as
/// Settings. Each step is logged to `Application Support/dev-setup.log`.
public enum DevSetup {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    public static var isRequested: Bool { env["DEV_SETUP"] != nil }

    public static func value(_ name: String) -> String? {
        env[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Ids separated by "|".
    public static func list(_ name: String) -> [String] {
        (value(name) ?? "").split(separator: "|").map(String.init)
    }

    /// Set once with `DEV_HOLD_PROGRESS=1` (before the environment is made): reading, watching
    /// and listening places stay queued on this simulator instead of moving the real ones.
    public static func holdsProgress() -> Bool {
        if isRequested, env["DEV_HOLD_PROGRESS"] == "1" {
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: holdMarker.path(percentEncoded: false), contents: Data())
        }
        return FileManager.default.fileExists(atPath: holdMarker.path(percentEncoded: false))
    }

    private static var holdMarker: URL { URL.applicationSupportDirectory.appending(path: "dev-holds-progress") }

    public static func log(_ line: String) {
        let file = URL.applicationSupportDirectory.appending(path: "dev-setup.log")
        let entry = Data("\(Date.now.formatted(.iso8601)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: file)
        }
    }

    public static func log(_ step: String, _ status: ConnectionStatus) {
        switch status {
        case .ok(let message): log("\(step): ok · \(message)")
        case .failed(let message): log("\(step): FAILED · \(message)")
        case .idle, .working: log("\(step): skipped")
        }
    }

    /// What the apps share: AnkiConnect and the card settings (`DEV_ANKI_SETTINGS`, AnkiSettings
    /// JSON), dictionaries (`DEV_IMPORT_DICTIONARIES`, zips in order), audio sources
    /// (`DEV_AUDIO_SOURCES`, AudioSourceRecord JSON), the kechimochi address (`DEV_KECHIMOCHI_URL`,
    /// each app's own), Audiobookshelf (an API key) and Kaku.
    @MainActor public static func applyCommon(_ common: CommonEnvironment) async {
        if let url = value("DEV_ANKI_URL") {
            let model = AnkiSettingsModel(environment: common)
            model.urlText = url
            model.apiKey = value("DEV_ANKI_KEY") ?? ""
            await model.testAndSave()
            log("AnkiConnect", model.status)
        }
        if let json = value("DEV_ANKI_SETTINGS") {
            do {
                try common.ankiSettings.save(JSONDecoder().decode(AnkiSettings.self, from: Data(json.utf8)))
                log("Card settings: ok · tags \(try common.ankiSettings.settings().tags)")
            } catch {
                log("Card settings: FAILED · \(error)")
            }
        }
        if let json = value("DEV_AUDIO_SOURCES") {
            do {
                let sources = try JSONDecoder().decode([AudioSourceRecord].self, from: Data(json.utf8))
                try common.lookup.audio.delete(ids: try common.lookup.audio.sources().compactMap(\.id))
                for source in sources { try common.lookup.audio.save(source) }
                log("Audio sources: ok · \(sources.map(\.name))")
            } catch {
                log("Audio sources: FAILED · \(error)")
            }
        }
        if let url = value("DEV_KECHIMOCHI_URL") {
            do {
                try common.activity.saveKechimochiURL(url)
                log("kechimochi: ok")
            } catch {
                log("kechimochi: FAILED · \(error)")
            }
        }
        for zip in list("DEV_IMPORT_DICTIONARIES") {
            do {
                _ = try await common.dictionaries.importDictionary(at: URL(filePath: zip))
                log("Dictionary \(URL(filePath: zip).lastPathComponent): ok")
            } catch {
                log("Dictionary \(URL(filePath: zip).lastPathComponent): FAILED · \(error)")
            }
        }
        try? await common.lookup.reload()
        await common.refreshMinedWords()
        log("Setup mode: \(common.setupMode.map { "\($0)" } ?? "no App Group") · holds progress: \(holdsProgress())")
    }

    /// Audiobookshelf with an API key and Kaku with its token (`DEV_ABS_URL/KEY`, `DEV_KAKU_URL/TOKEN`);
    /// Audiobookshelf only in the apps that use it (`tokens`).
    @MainActor public static func applyAudioServers(_ common: CommonEnvironment, tokens: AudiobookshelfTokens?) async {
        if let tokens, let url = value("DEV_ABS_URL"), let key = value("DEV_ABS_KEY") {
            let model = AudiobookshelfSettingsModel(environment: common, tokens: tokens)
            model.urlText = url
            model.method = .apiKey
            model.apiKey = key
            await model.signIn()
            log("Audiobookshelf", model.status)
        }
        if let url = value("DEV_KAKU_URL"), let token = value("DEV_KAKU_TOKEN") {
            let model = KakuSettingsModel(environment: common)
            model.urlText = url
            model.token = token
            await model.testAndSave()
            log("Kaku", model.status)
        }
    }
}
#endif
