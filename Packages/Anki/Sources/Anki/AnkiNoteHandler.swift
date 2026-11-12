import Core
import Foundation

/// Word audio for a card: the file and its extension.
public struct AudioClip: Sendable, Equatable {
    public var data: Data
    public var fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

/// Delivers mined cards to AnkiConnect.
public struct AnkiNoteHandler: OutboxHandler {
    public let kind = OutboxJobKind.ankiNote
    /// Built per send so changes in Settings take effect; nil when AnkiConnect isn't set up.
    let makeClient: @Sendable () throws -> AnkiConnectClient?
    let settings: @Sendable () throws -> AnkiSettings
    let fetchAudio: @Sendable (_ term: String, _ reading: String) async -> AudioClip?
    let minedWords: MinedWordStore
    let syncScheduler: AnkiSyncScheduler?
    /// Field names per note type, read once per launch.
    private let fieldNames = FieldNameCache()

    public init(
        makeClient: @escaping @Sendable () throws -> AnkiConnectClient?,
        settings: @escaping @Sendable () throws -> AnkiSettings,
        fetchAudio: @escaping @Sendable (_ term: String, _ reading: String) async -> AudioClip?,
        minedWords: MinedWordStore,
        syncScheduler: AnkiSyncScheduler? = nil
    ) {
        self.makeClient = makeClient
        self.settings = settings
        self.fetchAudio = fetchAudio
        self.minedWords = minedWords
        self.syncScheduler = syncScheduler
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        let card: MinedCard
        do {
            card = try job.decodePayload(MinedCard.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable card: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("AnkiConnect isn't set up.")
        }
        let fields = try await fieldNames.names(for: card.noteType) {
            do {
                return try await client.modelFieldNames(card.noteType)
            } catch {
                if case .message(let text)? = error as? ConnectionError, text.localizedCaseInsensitiveContains("not found") {
                    throw OutboxPermanentFailure("Anki has no note type named “\(card.noteType)”.")
                }
                throw error
            }
        }
        let mapping = try settings().fields.filter { fields.contains($0.key) }
        // Upload media only when a field shows it; the note then references the stored names.
        var pictureFile: String?
        if mapping.values.contains(.slot(.picture)), let item = media.first(where: { $0.field == MinedCard.pictureMedia }) {
            pictureFile = try await client.storeMediaFile(try Data(contentsOf: item.url), filename: Self.mediaFilename(item.url))
        }
        var sentenceAudioFile: String?
        if mapping.values.contains(.slot(.sentenceAudio)),
           let item = media.first(where: { $0.field == MinedCard.sentenceAudioMedia }) {
            sentenceAudioFile = try await client.storeMediaFile(try Data(contentsOf: item.url), filename: Self.mediaFilename(item.url))
        }
        var audioFile: String?
        if card.wantsAudio, mapping.values.contains(.slot(.audio)), let clip = await fetchAudio(card.expression, card.reading) {
            audioFile = try await client.storeMediaFile(
                clip.data, filename: Self.audioFilename(expression: card.expression, reading: card.reading, fileExtension: clip.fileExtension)
            )
        }

        let built: AnkiNoteBuilder.Result
        do {
            built = try AnkiNoteBuilder.note(for: card, mapping: mapping, fieldNames: fields, pictureFile: pictureFile, audioFile: audioFile,
                                           sentenceAudioFile: sentenceAudioFile)
        } catch let error as AnkiNoteBuilder.BuildError {
            throw OutboxPermanentFailure(error.localizedDescription)
        }
        do {
            _ = try await client.addNote(built.note)
        } catch .duplicate {
            // Mark it so the popup shows it's already there.
            try? minedWords.markInAnki(expression: card.expression, reading: card.reading)
            throw OutboxPermanentFailure(AnkiAddNoteError.duplicate.localizedDescription)
        } catch .rejected(let detail) {
            if detail.localizedCaseInsensitiveContains("model") || detail.localizedCaseInsensitiveContains("field") {
                await fieldNames.forget(card.noteType)
            }
            throw OutboxPermanentFailure(AnkiAddNoteError.rejected(detail).localizedDescription)
        } catch .connection(let error) {
            throw error
        }
        try? minedWords.markInAnki(expression: card.expression, reading: card.reading)
        await syncScheduler?.cardAdded()
    }

    /// Stable per word, so mining the same word twice reuses one media file.
    static func audioFilename(expression: String, reading: String, fileExtension: String) -> String {
        var hasher = StableHash()
        hasher.combine(expression + "|" + reading)
        return safeFilename("amatsubame_audio_\(hasher.hex).\(fileExtension)")
    }

    /// `amatsubame_<outbox file name>` with only `[a-z0-9_.]`.
    static func mediaFilename(_ file: URL) -> String {
        safeFilename("amatsubame_\(file.lastPathComponent)")
    }

    /// Media names Anki and AnkiConnect-compatible proxies keep as sent: some proxies store files
    /// under a lowercased name without saying so, so names are lowercase letters, digits, `_` and `.` only.
    static func safeFilename(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "." })
    }
}

actor FieldNameCache {
    private var names: [String: [String]] = [:]

    func names(for noteType: String, fetch: @Sendable () async throws -> [String]) async throws -> [String] {
        if let cached = names[noteType] { return cached }
        let fetched = try await fetch()
        names[noteType] = fetched
        return fetched
    }

    func forget(_ noteType: String) {
        names[noteType] = nil
    }
}

/// FNV-1a, for filenames that must not change between launches (unlike `Hasher`).
struct StableHash {
    private var value: UInt64 = 0xcbf29ce484222325

    mutating func combine(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
    }

    var hex: String { String(format: "%016llx", value) }
}
