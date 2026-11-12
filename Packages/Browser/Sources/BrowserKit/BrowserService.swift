import Anki
import AppCommon
import Core
import Darwin
import Dictionary
import Foundation
import Lookup

/// The extension's native side: lookup, audio and mining through the same services as the
/// apps (`CommonEnvironment`), kept for the life of the extension process (Safari reuses it
/// between messages). Answers `BrowserRequest`s with JSON-safe dictionaries for the JavaScript.
@MainActor
public final class BrowserService {
    public let common: CommonEnvironment
    /// Dictionary zips shipped inside the extension (dev builds), imported on first use, in
    /// this order, when the setup it uses has no dictionaries yet.
    let bundledDictionaries: [URL]
    private var isReady = false
    private var loaded: [DictionaryRecord] = []

    /// Recent lookups, for the popup's audio and Add to Anki buttons (by id).
    private var pages: [(id: String, page: LookupResultPage, source: String?)] = []
    static let keptPages = 8

    public var library: DictionaryLibrary { common.dictionaries }

    /// Remembers which built-in dictionaries are set up (by package name), which one was
    /// being set up when the process last stopped, and how often each failed.
    nonisolated(unsafe) let defaults: UserDefaults
    static let installedKey = "bundledDictionaries.installed"
    static let attemptingKey = "bundledDictionaries.attempting"
    static let failuresKey = "bundledDictionaries.failures"
    /// Built-in dictionaries that couldn't be set up on this device (twice), for the menu.
    public private(set) var skipped: [String] = []

    public init(common: CommonEnvironment, bundledDictionaries: [URL], defaults: UserDefaults = .standard) {
        self.common = common
        self.bundledDictionaries = bundledDictionaries
        self.defaults = defaults
    }

    /// The popup lists dictionaries in import order: bilingual ones (Jitendex, JMdict…) first,
    /// then grammar, then the rest (frequency, pitch and kanji are shown with the word).
    public nonisolated static func importOrder(_ zips: [URL]) -> [URL] {
        func rank(_ url: URL) -> Int {
            let name = url.lastPathComponent.lowercased()
            if name.contains("jitendex") || name.contains("[bilingual]") || name.contains("jmdict") { return 0 }
            if name.contains("[grammar]") { return 1 }
            if name.contains("[monolingual]") { return 2 }
            return 3
        }
        return zips.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }



    public static func make(bundledDictionaries: [URL]) -> BrowserService {
        BrowserService(common: BrowserEnvironment.make(), bundledDictionaries: bundledDictionaries)
    }

    public func handle(_ message: Any?) async -> [String: Any] {
        guard let request = BrowserRequest(message) else { return ["error": "Unknown message"] }
        let started = ContinuousClock.now
        do {
            let prepared = try await prepare()
            switch request {
            case .status:
                return status(prepareMs: prepared)
            case .lookup(let text, let offset, let title, let url):
                let lookupStart = ContinuousClock.now
                let page = await common.lookup.lookup(text: text, utf16Offset: offset)
                let lookupMs = Self.milliseconds(ContinuousClock.now - lookupStart)
                var response = present(page, source: Self.source(title: title, url: url))
                response["matchLength"] = page.results.first?.matched.utf16.count ?? 0
                response["stats"] = stats(prepareMs: prepared, lookupMs: lookupMs, totalMs: Self.milliseconds(ContinuousClock.now - started))
                return response
            case .query(let query):
                return present(await common.lookup.search(query), source: nil)
            case .audio(let id, let index):
                guard let result = result(id, index) else { return ["error": "Look the word up again."] }
                guard let clip = await common.lookup.audio.firstClip(term: result.expression, reading: result.reading) else {
                    return ["error": "No audio for \(result.expression)."]
                }
                return ["audio": clip.data.base64EncodedString(), "type": Self.mimeType(clip.fileExtension)]
            case .mine(let id, let index):
                return await mine(id, index)
            case .undo(let jobId):
                return ["undone": common.mining.cancel(jobId)]
            case .send(let jobId):
                return await send(jobId)
            case .saveAnki(let url, let apiKey, let deck):
                return await saveAnki(url: url, apiKey: apiKey, deck: deck)
            case .marks(let texts):
                return await marks(texts)
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: Word marks

    /// When the mined words were last asked of Anki (the extension asks again every 10 minutes).
    private var minedWordsRefreshed: Date?

    /// Word marks for page paragraphs, as Yomu marks books (Settings ▸ Lookup ▸ word marks):
    /// per text, `[UTF-16 offset, length, "km-new" | "km-learning"]`; known words aren't marked.
    func marks(_ texts: [String]) async -> [String: Any] {
        // Off until Anki is connected: with no mined words, every word would be marked.
        guard (try? common.ankiSettings.settings().marksWords) ?? true, (try? common.accounts.account(.anki)) != nil else {
            return ["marks": [], "off": true]
        }
        if minedWordsRefreshed.map({ Date.now.timeIntervalSince($0) > 600 }) ?? true {
            minedWordsRefreshed = .now
            await common.refreshMinedWords()
        }
        let states = common.mining.wordMarks()
        var marks: [[[Any]]] = []
        for text in texts {
            let words = await library.scanner.words(in: text)
            marks.append(words.compactMap { word in
                switch states.state(expression: word.expression, reading: word.reading) {
                case .notInAnki: [word.offset, word.length, "km-new"]
                case .learning: [word.offset, word.length, "km-learning"]
                case .known: nil
                }
            })
        }
        return ["marks": marks, "accent": common.lookup.accent?.color ?? BrowserEnvironment.accent.color]
    }

    // MARK: Lookup

    /// Imports the bundled dictionaries the first time, then loads them; afterwards reloads
    /// if another app changed them. Returns how long it took (nil when nothing to do).
    func prepare() async throws -> Int? {
        if isReady {
            let current = try library.dictionaries()
            guard current != loaded else { return nil }
            let start = ContinuousClock.now
            try await common.lookup.reload()
            loaded = current
            return Self.milliseconds(ContinuousClock.now - start)
        }
        let start = ContinuousClock.now
        library.removeUnfinishedImports()
        if common.setupMode == .shared {
            // The other apps manage the shared dictionaries; built-in ones only fill an empty setup.
            if try library.dictionaries().isEmpty {
                for item in bundledDictionaries { _ = try? await install(item) }
            }
        } else {
            try await syncBundled()
        }
        try? common.lookup.audio.installDefaultSourcesIfNeeded()
        try? common.lookup.audio.moveKeysToKeychain()
        try await common.lookup.reload()
        loaded = try library.dictionaries()
        try? await common.worker.recover()
        isReady = true
        return Self.milliseconds(ContinuousClock.now - start)
    }

    /// The extension's own setup holds only its built-in dictionaries (there's nowhere else to
    /// add them): set up the ones missing, one at a time, remembering progress, so a process
    /// stopped mid-way (iOS limits extensions) resumes instead of starting over; remove ones a
    /// newer build no longer carries. One that stops the process twice is skipped.
    func syncBundled() async throws {
        var installed = defaults.dictionary(forKey: Self.installedKey) as? [String: String] ?? [:]
        var failures = defaults.dictionary(forKey: Self.failuresKey) as? [String: Int] ?? [:]
        if let attempting = defaults.string(forKey: Self.attemptingKey) {
            failures[attempting, default: 0] += 1
            defaults.removeObject(forKey: Self.attemptingKey)
            defaults.set(failures, forKey: Self.failuresKey)
        }
        let names = bundledDictionaries.map(\.lastPathComponent)
        installed = installed.filter { names.contains($0.key) }
        let keep = Set(installed.values)
        for dictionary in try library.dictionaries() where !keep.contains(dictionary.id) {
            try await library.delete(dictionary.id)
        }
        let present = Set(try library.dictionaries().map(\.id))
        installed = installed.filter { present.contains($0.value) }
        defaults.set(installed, forKey: Self.installedKey)

        for item in bundledDictionaries where installed[item.lastPathComponent] == nil
            && failures[item.lastPathComponent, default: 0] < 2 {
            let name = item.lastPathComponent
            defaults.set(name, forKey: Self.attemptingKey)
            do {
                installed[name] = try await install(item).id
                defaults.set(installed, forKey: Self.installedKey)
            } catch {
                failures[name, default: 0] += 1
                defaults.set(failures, forKey: Self.failuresKey)
            }
            defaults.removeObject(forKey: Self.attemptingKey)
        }
        // Popup order follows the build's order.
        let ordered = names.compactMap { installed[$0] }
        if try library.dictionaries().map(\.id) != ordered, !ordered.isEmpty { try await library.reorder(ordered) }
        skipped = names.filter { installed[$0] == nil }.map { ($0 as NSString).deletingPathExtension }
    }

    /// A prebuilt package (`.hoshidict`, just copied) or a zip (imported).
    private func install(_ item: URL) async throws -> DictionaryRecord {
        item.pathExtension == "hoshidict"
            ? try await library.installPrebuilt(at: item).dictionary
            : try await library.importDictionary(at: item).dictionary
    }

    private func present(_ page: LookupResultPage, source: String?) -> [String: Any] {
        let id = UUID().uuidString
        pages.append((id, page, source))
        if pages.count > Self.keptPages { pages.removeFirst(pages.count - Self.keptPages) }
        return ["id": id, "found": !page.results.isEmpty, "html": common.lookup.document(for: page)]
    }

    private func result(_ id: String, _ index: Int) -> TermLookupResult? {
        guard let entry = pages.last(where: { $0.id == id }), entry.page.results.indices.contains(index) else { return nil }
        return entry.page.results[index]
    }

    /// The card's MiscInfo: the page's title and address.
    static func source(title: String?, url: String?) -> String? {
        let parts = [title, url].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Mining

    struct WebPage: MiningContext {
        let miscInfo: String
        func pictureData() async -> Data? { nil }
    }

    /// Queues the card (kept until AnkiConnect takes it). Like the apps, it waits a few seconds
    /// (`MiningService.undoWindow`) so it can be undone; the popup then asks to send.
    private func mine(_ id: String, _ index: Int) async -> [String: Any] {
        guard let entry = pages.last(where: { $0.id == id }), entry.page.results.indices.contains(index) else {
            return ["error": "Look the word up again."]
        }
        guard common.ankiClient() != nil else {
            return ["error": common.setupMode == .shared
                ? "Set up AnkiConnect in the Hiku app first."
                : "Set up AnkiConnect in the extension\u{2019}s menu first (the puzzle piece in Safari\u{2019}s address bar)."]
        }
        do {
            let mined = try await common.mining.mine(entry.page.results[index], sentence: entry.page.sentence,
                                                     context: entry.source.map(WebPage.init))
            return ["mined": true, "jobId": mined.jobId, "undoSeconds": MiningService.undoWindow]
        } catch {
            return ["error": "Couldn\u{2019}t make the card: \(error.localizedDescription)"]
        }
    }

    /// Sends what's due and reports how the card `jobId` fared. A send already running (the
    /// queue's own retry) may be the one that takes it, so this waits briefly for its state.
    private func send(_ jobId: Int64) async -> [String: Any] {
        await common.worker.drain()
        var job = (try? common.outbox.job(jobId))?.job
        for _ in 0..<30 where job?.state == .inFlight || job?.state == .pending && job.map({ $0.nextAttemptAt <= Date() }) == true {
            try? await Task.sleep(for: .milliseconds(500))
            job = (try? common.outbox.job(jobId))?.job
        }
        switch job?.state {
        case .sent?, nil:
            // A sent card may already be pruned from the queue.
            return ["mined": true, "sent": true]
        case .failed?:
            return ["mined": true, "sent": false,
                    "message": "Anki didn\u{2019}t take the card: \(job?.lastError ?? "unknown error")."]
        default:
            return ["mined": true, "sent": false,
                    "message": "Saved. It goes to Anki when AnkiConnect can be reached"
                        + (job?.lastError.map { " (\($0))." } ?? ".")]
        }
    }

    // MARK: Settings

    private func status(prepareMs: Int?) -> [String: Any] {
        var response: [String: Any] = [
            "ready": true,
            "dictionaries": (try? library.dictionaries().map(\.title)) ?? [],
            "skipped": skipped,
            "managedByApp": common.setupMode == .shared,
            "stats": stats(prepareMs: prepareMs, lookupMs: nil),
        ]
        if let account = try? common.accounts.account(.anki) {
            response["anki"] = [
                "url": account.baseURL.absoluteString,
                "deck": (try? common.ankiSettings.settings().deck) ?? "",
                "hasKey": ((try? common.secrets.secret(for: .ankiAPIKey)) ?? nil) != nil,
            ]
        }
        return response
    }

    /// Checks the server, then saves it (and the deck) for this extension.
    private func saveAnki(url text: String, apiKey: String, deck: String) async -> [String: Any] {
        guard common.setupMode != .shared else { return ["error": "AnkiConnect is set in the Hiku app."] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"), url.host() != nil else {
            return ["error": "That doesn\u{2019}t look like a server address."]
        }
        // The menu can't show a saved key back; "\0keep" means keep the one saved.
        let key = apiKey == "\u{0}keep"
            ? ((try? common.secrets.secret(for: .ankiAPIKey)) ?? nil) ?? ""
            : apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let client = AnkiConnectClient(baseURL: url, apiKey: key.isEmpty ? nil : key, http: common.http)
            let check = try await client.testConnection()
            try common.secrets.setSecret(key.isEmpty ? nil : key, for: .ankiAPIKey)
            try common.accounts.save(ServerAccount(kind: .anki, baseURL: url, serverName: "AnkiConnect",
                                                   serverVersion: String(check.version), lastCheckedAt: .now))
            let decks = (try? await client.deckNames()) ?? []
            let chosen = deck.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chosen.isEmpty {
                var settings = try common.ankiSettings.settings()
                settings.deck = chosen
                try common.ankiSettings.save(settings)
            }
            return ["ok": true, "version": check.version, "decks": decks,
                    "deck": (try? common.ankiSettings.settings().deck) ?? chosen]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: Helpers

    private func stats(prepareMs: Int?, lookupMs: Int?, totalMs: Int? = nil) -> [String: Any] {
        var stats: [String: Any] = ["memoryMB": Self.footprintMB()]
        if let prepareMs { stats["prepareMs"] = prepareMs }
        if let lookupMs { stats["lookupMs"] = lookupMs }
        if let totalMs { stats["totalMs"] = totalMs }
        return stats
    }

    static func mimeType(_ fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "aac", "mp4": "audio/mp4"
        case "ogg", "oga", "opus": "audio/ogg"
        case "wav": "audio/wav"
        default: "application/octet-stream"
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// This process's memory as iOS counts it against its limit (phys_footprint), in MB.
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}
