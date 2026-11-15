import Dictionary
import Foundation

/// A linked client of a Hachidori host, like a linked browser (docs/hachidori.md sections 1–4):
/// it keeps the link open with Hachidori's backoff, answers pings, mirrors the shared records and
/// sends requests. There's no queue: a request waits a few seconds for the link, then fails, and
/// a write cut off by a dropped link is reported as `outcomeUnknown`, never retried.
public actor HachidoriLink {
    /// The Origin the relay accepts from native clients (hachidori-anki v0.0.4 and later).
    public static let origin = "hoshi://hoshidicts"

    public enum Status: Equatable, Sendable {
        case stopped
        case connecting
        /// Linked to the host that sent this hello.
        case linked(name: String, version: String, capabilities: [String])
        /// Not linked; the next try is in `retryIn`.
        case waiting(retryIn: Duration)
    }

    public enum Update: Equatable, Sendable {
        case status(Status)
        /// These shared keys changed (a hello replaces all six).
        case records(Set<String>)
        /// The host's Anki index changed: known/learning words should be asked again.
        case wordStatus(revision: Int)
    }

    public struct Timing: Sendable {
        /// How long a request waits for the link before failing (Hachidori: 5 s).
        public var linkWait: Duration = .seconds(5)
        /// How long a reply may take (Mangatan: 15 s).
        public var reply: Duration = .seconds(15)
        /// Reconnect after min(`backoffMax`, `backoffBase`·2ⁿ) (Hachidori: 0.5–10 s).
        public var backoffBase: Duration = .milliseconds(500)
        public var backoffMax: Duration = .seconds(10)

        public init() {}
    }

    public let url: URL
    let clientName: String
    let clientVersion: String
    let transport: any SharingTransport
    let timing: Timing

    public private(set) var status: Status = .stopped
    public private(set) var records = SharedRecords()
    /// The host engine's generation from its latest engine reply (`hd_media` needs the current one).
    public private(set) var generation: Int?

    private var runTask: Task<Void, Never>?
    private var socket: (any SharingSocket)?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Result<JSONValue, HachidoriError>, Never>] = [:]
    private var linkWaiters: [UUID: CheckedContinuation<Result<any SharingSocket, HachidoriError>, Never>] = [:]
    private var observers: [UUID: AsyncStream<Update>.Continuation] = [:]

    /// `url` is the relay's `/link`, e.g. `ws://<host>:8771/link`.
    public init(url: URL, clientName: String, clientVersion: String,
                transport: any SharingTransport = URLSessionSharingTransport(), timing: Timing = Timing()) {
        self.url = url
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.transport = transport
        self.timing = timing
    }

    /// `ws://<host>:8771/link` from what a user types: a host, host:port or a full URL.
    public static func linkURL(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "ws://" + text }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }
        guard components.scheme == "ws" || components.scheme == "wss" else { return nil }
        if components.port == nil { components.port = 8771 }
        if components.path.isEmpty || components.path == "/" { components.path = "/link" }
        return components.url
    }

    // MARK: Link

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.close()
        drop()
        setStatus(.stopped)
    }

    public func updates() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream.makeStream(of: Update.self)
        let id = UUID()
        observers[id] = continuation
        continuation.yield(.status(status))
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            setStatus(.connecting)
            do {
                let socket = try await transport.connect(to: url, origin: Self.origin)
                self.socket = socket
                try await socket.send(ClientFrame.hello(version: clientVersion, name: clientName).json)
                while !Task.isCancelled {
                    let text = try await socket.receive()
                    if try await handle(text, on: socket) { attempt = 0 }
                }
            } catch {}
            socket?.close()
            drop()
            guard !Task.isCancelled else { break }
            let delay = min(timing.backoffMax, timing.backoffBase * (1 << min(attempt, 16)))
            attempt += 1
            setStatus(.waiting(retryIn: delay))
            try? await Task.sleep(for: delay)
        }
    }

    /// Handles one frame; true when it was the host's hello.
    private func handle(_ text: String, on socket: any SharingSocket) async throws -> Bool {
        guard let frame = try? HostFrame(json: text) else { return false }
        switch frame {
        case .hello(let hello):
            guard hello.protocolVersion == ClientFrame.protocolVersion else { throw HachidoriError.malformed("protocol \(hello.protocolVersion)") }
            records.apply(snapshot: hello.snapshot)
            setStatus(.linked(name: hello.name, version: hello.version, capabilities: hello.capabilities))
            broadcast(.records(Set(SharedRecords.snapshotKeys)))
            for (id, waiter) in linkWaiters {
                linkWaiters[id] = nil
                waiter.resume(returning: .success(socket))
            }
            return true
        case .reply(let id, let response):
            if let generation = response["generation"]?.int { self.generation = generation }
            let result: Result<JSONValue, HachidoriError> = response["ok"]?.bool == true
                ? .success(response)
                : .failure(.host(message: response["error"]?.string ?? "Hachidori refused the request.", code: response["errorCode"]?.string))
            pending.removeValue(forKey: id)?.resume(returning: result)
        case .storage(let changes):
            records.apply(changes: changes)
            broadcast(.records(Set(changes.keys)))
        case .wordStatus(let revision):
            broadcast(.wordStatus(revision: revision))
        case .ping:
            try await socket.send(ClientFrame.pong.json)
        case .bye:
            throw HachidoriError.notLinked
        case .unknown:
            break
        }
        return false
    }

    /// The link is gone: requests in flight have an unknown outcome.
    private func drop() {
        socket = nil
        for (id, continuation) in pending {
            pending[id] = nil
            continuation.resume(returning: .failure(.outcomeUnknown))
        }
    }

    private func setStatus(_ status: Status) {
        guard self.status != status else { return }
        self.status = status
        broadcast(.status(status))
    }

    private func broadcast(_ update: Update) {
        for observer in observers.values { observer.yield(update) }
    }

    // MARK: Requests

    /// Sends one request and returns the host's reply (`ok` true), waiting a few seconds for the link.
    public func request(_ target: String, _ type: String, _ fields: [String: JSONValue] = [:]) async throws(HachidoriError) -> JSONValue {
        let socket = try await linkedSocket().get()
        nextID += 1
        let id = nextID
        var message = fields
        message["target"] = .string(target)
        message["type"] = .string(type)
        message["requestId"] = .number(Double(id))
        let frame = ClientFrame.request(id: id, message: message).json
        let reply = timing.reply
        return try await withCheckedContinuation { (continuation: CheckedContinuation<Result<JSONValue, HachidoriError>, Never>) in
            pending[id] = continuation
            Task {
                do {
                    try await socket.send(frame)
                } catch {
                    self.finish(id, .failure(.outcomeUnknown))
                    return
                }
                try? await Task.sleep(for: reply)
                self.finish(id, .failure(.timedOut))
            }
        }.get()
    }

    private func finish(_ id: Int, _ result: Result<JSONValue, HachidoriError>) {
        pending.removeValue(forKey: id)?.resume(returning: result)
    }

    private func linkedSocket() async -> Result<any SharingSocket, HachidoriError> {
        if case .linked = status, let socket { return .success(socket) }
        guard runTask != nil else { return .failure(.notLinked) }
        let id = UUID()
        let wait = timing.linkWait
        return await withCheckedContinuation { continuation in
            linkWaiters[id] = continuation
            Task {
                try? await Task.sleep(for: wait)
                self.linkWaitEnded(id)
            }
        }
    }

    private func linkWaitEnded(_ id: UUID) {
        linkWaiters.removeValue(forKey: id)?.resume(returning: .failure(.notLinked))
    }

    // MARK: The requests the apps use

    /// Looks `text` up on the host with its own settings (`termPayload` in Hachidori's content.js).
    public func lookup(_ text: String, maxResults: Int? = nil, scanLength: Int? = nil) async throws(HachidoriError) -> HostLookupPage {
        // The settings come with the hello, so wait for the link before reading them.
        _ = try await linkedSocket().get()
        let options = records.options
        let reply = try await request("hoshidicts-offscreen", "hd_lookup", [
            "text": .string(text),
            "maxResults": .number(Double(maxResults ?? options.maxResults)),
            "scanLength": .number(Double(scanLength ?? options.scanLength)),
            "options": ["frequencyDictionary": .string(options.frequencyDictionary),
                        "frequencyOrder": .string(options.frequencyOrder), "primaryReading": ""],
        ])
        return try HostLookupPage(response: reply)
    }

    /// A dictionary's image as a `data:` URL, for the current engine generation.
    public func media(dictionary: String, path: String) async throws(HachidoriError) -> String {
        let reply = try await request("hoshidicts-offscreen", "hd_media", [
            "dictionary": .string(dictionary), "path": .string(path), "generation": .number(Double(generation ?? 0)),
        ])
        guard let url = reply["dataUrl"]?.string else { throw .malformed("a media reply without data") }
        return url
    }

    /// Each dictionary's CSS (dictionary title → styles).
    public func styles() async throws(HachidoriError) -> [String: String] {
        let reply = try await request("hoshidicts-offscreen", "hd_styles")
        var styles: [String: String] = [:]
        for entry in reply["styles"]?.array ?? [] {
            if let dictionary = entry["dictionary"]?.string, let css = entry["styles"]?.string { styles[dictionary] = css }
        }
        return styles
    }

    /// Counts one lookup of a headword (the first result's expression and reading) with the host's
    /// clock. Returns the row, or nil when the host has lookup counts turned off.
    @discardableResult
    public func recordLookup(term: String, reading: String) async throws(HachidoriError) -> HostLookupCount? {
        try await lookupStats("hd_lookup_stats_record", term: term, reading: reading)
    }

    /// The count for a headword, without adding one.
    public func lookupCount(term: String, reading: String) async throws(HachidoriError) -> HostLookupCount? {
        try await lookupStats("hd_lookup_stats_read", term: term, reading: reading)
    }

    private func lookupStats(_ type: String, term: String, reading: String) async throws(HachidoriError) -> HostLookupCount? {
        let reply = try await request("hoshidicts-worker", type, [
            "term": .string(HostLookupCount.normalized(term)), "reading": .string(HostLookupCount.normalized(reading)),
        ])
        guard let statistics = reply["statistics"], statistics != .null else { return nil }
        guard let row = try? statistics.decode(HostLookupCount.self) else { throw .malformed("an unreadable lookup count") }
        return row
    }

    public enum WordStatus: String, Sendable {
        case known, ignored
    }

    /// Marks a headword known or ignored, or clears its mark (nil). Returns the new revision.
    @discardableResult
    public func setWordStatus(_ status: WordStatus?, for headword: String) async throws(HachidoriError) -> Int {
        let reply = try await request("hoshidicts-worker", "hd_word_status_override", [
            "headword": .string(headword), "status": status.map { JSONValue.string($0.rawValue) } ?? .null,
        ])
        return reply["revision"]?.int ?? 0
    }

    /// Adds an entry to the host's personal dictionary.
    public func appendCustomEntry(term: String, reading: String, definition: String) async throws(HachidoriError) {
        _ = try await request("hoshidicts-offscreen", "hd_custom_append", [
            "entry": ["term": .string(term), "reading": .string(reading), "definition": .string(definition)],
        ])
    }
}
