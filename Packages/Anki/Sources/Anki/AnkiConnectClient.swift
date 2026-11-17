import Core
import Foundation

// Targets AnkiConnect API version 6. Some AnkiConnect-compatible proxies require
// `Content-Type: application/json` (422 otherwise) and don't implement
// `requestPermission`, so neither is relied on. Errors come back as HTTP 200 with `error` set.

public struct AnkiConnectCheck: Equatable, Sendable {
    public var version: Int
    public var deckCount: Int

    public init(version: Int, deckCount: Int) {
        self.version = version
        self.deckCount = deckCount
    }
}

public struct AnkiConnectClient: Sendable {
    public static let apiVersion = 6

    public let baseURL: URL
    public let apiKey: String?
    public let http: HTTPClient

    public init(baseURL: URL, apiKey: String? = nil, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.http = http
    }

    private struct Request<Params: Encodable>: Encodable {
        var action: String
        var version: Int
        var key: String?
        var params: Params?
    }

    private struct Response<Result: Decodable>: Decodable {
        var result: Result?
        var error: String?
    }

    private struct NoParams: Encodable {}

    public func invoke<Result: Decodable>(
        _ action: String,
        as type: Result.Type = Result.self
    ) async throws(ConnectionError) -> Result {
        try await invoke(action, params: NoParams?.none, as: type)
    }

    public func invoke<Result: Decodable>(
        _ action: String,
        params: (some Encodable)?,
        as type: Result.Type = Result.self
    ) async throws(ConnectionError) -> Result {
        let request: URLRequest
        do {
            request = try .json("POST", baseURL, body: Request(action: action, version: Self.apiVersion, key: apiKey, params: params))
        } catch {
            throw .message(error.localizedDescription)
        }
        let response: Response<Result>
        do {
            response = try await http.decode(Response<Result>.self, from: request)
        } catch .unexpectedResponse, .server(status: 404), .server(status: 405) {
            throw .notThisService("Expected an AnkiConnect server.")
        }
        if let error = response.error {
            if error.localizedCaseInsensitiveContains("api key") { throw .unauthorized }
            throw .message(Self.prefix + error)
        }
        if let result = response.result { return result }
        // Actions without a meaningful result (some proxies return null for storeMediaFile).
        if let optional = Result.self as? any ExpressibleByNilLiteral.Type, let none = optional.init(nilLiteral: ()) as? Result {
            return none
        }
        throw .unexpectedResponse("AnkiConnect returned no result for \(action).")
    }

    static let prefix = "AnkiConnect: "

    public func version() async throws(ConnectionError) -> Int {
        try await invoke("version")
    }

    public func deckNames() async throws(ConnectionError) -> [String] {
        try await invoke("deckNames")
    }

    public func modelNames() async throws(ConnectionError) -> [String] {
        try await invoke("modelNames")
    }

    private struct ModelParams: Encodable { var modelName: String }
    private struct QueryParams: Encodable { var query: String }
    private struct NotesParams: Encodable { var notes: [Int64] }
    private struct NoteParams: Encodable { var note: AnkiNote }
    private struct MediaParams: Encodable { var filename: String; var data: String }

    /// Stores a file in Anki's media folder and returns the name it was stored under
    /// (AnkiConnect may rename it; some proxies return nothing, keeping the name).
    public func storeMediaFile(_ data: Data, filename: String) async throws(ConnectionError) -> String {
        let stored: String? = try await invoke("storeMediaFile", params: MediaParams(filename: filename, data: data.base64EncodedString()))
        return stored ?? filename
    }

    public func modelFieldNames(_ model: String) async throws(ConnectionError) -> [String] {
        try await invoke("modelFieldNames", params: ModelParams(modelName: model))
    }

    public func findNotes(_ query: String) async throws(ConnectionError) -> [Int64] {
        try await invoke("findNotes", params: QueryParams(query: query))
    }

    public func notesInfo(_ ids: [Int64]) async throws(ConnectionError) -> [AnkiNoteInfo] {
        try await invoke("notesInfo", params: NotesParams(notes: ids))
    }

    /// Adds a note and returns its id. Media in the note is uploaded with it.
    public func addNote(_ note: AnkiNote) async throws(AnkiAddNoteError) -> Int64 {
        do {
            return try await invoke("addNote", params: NoteParams(note: note))
        } catch {
            throw AnkiAddNoteError(error)
        }
    }

    /// Syncs the server's collection with the sync server its Anki uses (AnkiWeb or a
    /// self-hosted one; the server has its own login). AnkiConnect answers null; some
    /// proxies answer with a status report, so any result goes.
    public func sync() async throws(ConnectionError) {
        do {
            let _: AnyResult? = try await invoke("sync")
        } catch .message(let message) {
            throw .message(Self.syncMessage(message))
        }
    }

    /// The answers to `sync` that need the user to do something, in plain words. Anything
    /// else (e.g. a sync already in progress, which the scheduler retries) is kept.
    static func syncMessage(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("unsupported action") {
            return "This AnkiConnect server can't sync. Turn off Sync After Adding, or sync in Anki."
        }
        if lower.contains("not configured") {
            return "The Anki behind AnkiConnect isn't signed in to a sync server. Sign in to sync in Anki first."
        }
        if lower.contains("sync status") || lower.contains("fullsync") || lower.contains("full sync") {
            return "Anki needs a one-way full sync. Sync once in Anki and choose which side to keep."
        }
        return message
    }

    /// A result whose content doesn't matter (any JSON).
    struct AnyResult: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    public func testConnection() async throws(ConnectionError) -> AnkiConnectCheck {
        let version = try await version()
        return AnkiConnectCheck(version: version, deckCount: try await deckNames().count)
    }
}
