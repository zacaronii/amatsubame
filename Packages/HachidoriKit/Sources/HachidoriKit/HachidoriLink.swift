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

    public nonisolated let url: URL
    let clientName: String
    let clientVersion: String
    let transport: any SharingTransport
    let timing: Timing

    public private(set) var status: Status = .stopped
    public private(set) var records = SharedRecords()
    /// The host's latest hello: its name, version and dictionary count.
    public private(set) var hello: HostHello?
    /// The host engine's generation from its latest engine reply (`hd_media` needs the current one).
    public private(set) var generation: Int?

    private var runTask: Task<Void, Never>?
    /// The backoff wait between tries, which `reconnectNow` cuts short.
    private var backoff: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
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

    /// Settings ▸ Hachidori's Test Connection: links to `url` once and returns the host's hello,
    /// or fails with `notLinked` when no hello came within `timeout`.
    public static func probe(url: URL, clientName: String, clientVersion: String,
                             transport: any SharingTransport = URLSessionSharingTransport(),
                             timeout: Duration = .seconds(6)) async throws(HachidoriError) -> HostHello {
        var timing = Timing()
        timing.linkWait = timeout
        let link = HachidoriLink(url: url, clientName: clientName, clientVersion: clientVersion, transport: transport, timing: timing)
        await link.start()
        let linked = await link.linkedSocket()
        let hello = await link.hello
        await link.stop()
        guard case .success = linked, let hello else { throw .notLinked }
        return hello
    }

    // MARK: Link

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        endBackoff()
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
            let id = UUID()
            await withCheckedContinuation { continuation in
                backoff = (id, continuation)
                Task {
                    try? await Task.sleep(for: delay)
                    self.endBackoff(id)
                }
            }
        }
    }

    /// Tries again now instead of after the backoff (the app came to the front, or Sync Now).
    /// Does nothing while linked, stopped or already connecting.
    public func reconnectNow() {
        endBackoff()
    }

    /// Ends the backoff wait (only the one with `id`, when given: an earlier wait's timer
    /// mustn't cut a later one short).
    private func endBackoff(_ id: UUID? = nil) {
        guard let backoff, id == nil || backoff.id == id else { return }
        self.backoff = nil
        backoff.continuation.resume()
    }

    /// Handles one frame; true when it was the host's hello.
    private func handle(_ text: String, on socket: any SharingSocket) async throws -> Bool {
        guard let frame = try? HostFrame(json: text) else { return false }
        switch frame {
        case .hello(let hello):
            guard hello.protocolVersion == ClientFrame.protocolVersion else { throw HachidoriError.malformed("protocol \(hello.protocolVersion)") }
            records.apply(snapshot: hello.snapshot)
            self.hello = hello
            // The records first: whoever sees "linked" can read the host's settings at once.
            broadcast(.records(Set(SharedRecords.snapshotKeys)))
            setStatus(.linked(name: hello.name, version: hello.version, capabilities: hello.capabilities))
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
    /// `timeout` replaces the usual reply timeout (a tap shouldn't wait 15 s).
    public func request(_ target: String, _ type: String, _ fields: [String: JSONValue] = [:],
                        timeout: Duration? = nil) async throws(HachidoriError) -> JSONValue {
        let socket = try await linkedSocket().get()
        nextID += 1
        let id = nextID
        var message = fields
        message["target"] = .string(target)
        message["type"] = .string(type)
        message["requestId"] = .number(Double(id))
        let frame = ClientFrame.request(id: id, message: message).json
        let reply = timeout ?? timing.reply
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
    public func lookup(_ text: String, maxResults: Int? = nil, scanLength: Int? = nil,
                       timeout: Duration? = nil) async throws(HachidoriError) -> HostLookupPage {
        // The settings come with the hello, so wait for the link before reading them.
        _ = try await linkedSocket().get()
        let options = records.options
        let reply = try await request("hoshidicts-offscreen", "hd_lookup", [
            "text": .string(text),
            "maxResults": .number(Double(maxResults ?? options.maxResults)),
            "scanLength": .number(Double(scanLength ?? options.scanLength)),
            "options": ["frequencyDictionary": .string(options.frequencyDictionary),
                        "frequencyOrder": .string(options.frequencyOrder), "primaryReading": ""],
        ], timeout: timeout)
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

    /// A dictionary's image, decoded from `media(dictionary:path:)`'s `data:` URL.
    public func mediaData(dictionary: String, path: String) async throws(HachidoriError) -> Data {
        let url = try await media(dictionary: dictionary, path: path)
        guard let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
            throw .malformed("an unreadable image")
        }
        return data
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
    public func recordLookup(term: String, reading: String, timeout: Duration? = nil) async throws(HachidoriError) -> HostLookupCount? {
        try await lookupStats("hd_lookup_stats_record", term: term, reading: reading, timeout: timeout)
    }

    /// The count for a headword, without adding one.
    public func lookupCount(term: String, reading: String, timeout: Duration? = nil) async throws(HachidoriError) -> HostLookupCount? {
        try await lookupStats("hd_lookup_stats_read", term: term, reading: reading, timeout: timeout)
    }

    private func lookupStats(_ type: String, term: String, reading: String,
                             timeout: Duration? = nil) async throws(HachidoriError) -> HostLookupCount? {
        let reply = try await request("hoshidicts-worker", type, [
            "term": .string(HostLookupCount.normalized(term)), "reading": .string(HostLookupCount.normalized(reading)),
        ], timeout: timeout)
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

    // MARK: Sending a dictionary

    /// `linked-import-v1`'s target (Hachidori's extension/linked-import.js).
    static let linkedImportTarget = "hachidori-linked-import"
    static let linkedImportCapability = "linked-import-v1"
    /// Importing a large dictionary takes the host a while, and hachidori-docker's commit also
    /// waits for an import or update already running.
    static let commitTimeout: Duration = .seconds(600)

    /// Whether the linked host accepts dictionaries (`linked-import-v1`).
    public var acceptsDictionaries: Bool {
        if case .linked(_, _, let capabilities) = status { capabilities.contains(Self.linkedImportCapability) } else { false }
    }

    /// Sends a Yomitan zip to the host, as a linked browser's Settings does: `hd_import_begin`,
    /// the chunks in order, then `hd_import_commit` (`hd_import_abort` if a chunk fails). With
    /// `replace`, it replaces the host's dictionary of the same title; otherwise the host keeps
    /// both. Returns the host's import reply.
    @discardableResult
    public func sendDictionary(_ zip: URL, replace: Bool,
                               progress: @Sendable (Double) -> Void = { _ in }) async throws(HachidoriError) -> JSONValue {
        _ = try await linkedSocket().get()
        guard acceptsDictionaries else {
            throw .host(message: "This Hachidori doesn't accept dictionaries from other apps. Update it and try again.", code: nil)
        }
        let handle: FileHandle
        let size: Int
        do {
            handle = try FileHandle(forReadingFrom: zip)
            size = Int(try handle.seekToEnd())
            try handle.seek(toOffset: 0)
        } catch {
            throw .malformed("the dictionary couldn't be read: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let begin = try await request(Self.linkedImportTarget, "hd_import_begin", [
            "fileName": .string(zip.lastPathComponent), "size": .number(Double(size)), "replace": .bool(replace),
        ])
        guard let token = begin["token"]?.string, let chunkBytes = begin["chunkBytes"]?.int, chunkBytes > 0 else {
            throw .malformed("an unreadable upload reply")
        }
        do throws(HachidoriError) {
            var offset = 0
            while offset < size {
                let data: Data
                do {
                    data = try handle.read(upToCount: chunkBytes) ?? Data()
                } catch {
                    throw .malformed("the dictionary couldn't be read: \(error.localizedDescription)")
                }
                guard !data.isEmpty else { throw .malformed("the dictionary ended early") }
                // In order: the host refuses a chunk at any other offset.
                _ = try await request(Self.linkedImportTarget, "hd_import_chunk", [
                    "token": .string(token), "offset": .number(Double(offset)), "data": .string(data.base64EncodedString()),
                ])
                offset += data.count
                progress(Double(offset) / Double(size))
            }
        } catch {
            _ = try? await request(Self.linkedImportTarget, "hd_import_abort", ["token": .string(token)])
            throw error
        }
        return try await request(Self.linkedImportTarget, "hd_import_commit", ["token": .string(token)], timeout: Self.commitTimeout)
    }
}
