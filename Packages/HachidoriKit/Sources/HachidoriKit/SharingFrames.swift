import Foundation

/// What a client sends on `/link` (Hachidori's `extension/sharing-protocol.js`, `parseClientFrame`).
public enum ClientFrame: Equatable, Sendable {
    /// Always the first frame. Native clients send no capabilities.
    case hello(version: String, name: String)
    /// `message` carries `target`, `type` and `requestId` (= `id`) besides the request's own fields.
    case request(id: Int, message: [String: JSONValue])
    case pong

    public static let protocolVersion = 1

    public var json: String {
        let value: JSONValue = switch self {
        case .hello(let version, let name):
            ["kind": "hello", "protocol": .number(Double(Self.protocolVersion)), "version": .string(version),
             "name": .string(name), "capabilities": []]
        case .request(let id, let message):
            ["kind": "request", "id": .number(Double(id)), "message": .object(message)]
        case .pong:
            ["kind": "pong"]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
}

/// The host's first frame: who it is and its six shared records.
public struct HostHello: Equatable, Sendable {
    public var protocolVersion: Int
    public var version: String
    public var name: String
    public var dictionaryCount: Int
    public var capabilities: [String]
    /// `dictionaryState`, `options`, `customDictionarySource`, `dictionaryUpdates`, `lookupStats`
    /// and `wordStatusOverrides`, as stored. Lookup-count rows aren't in it.
    public var snapshot: [String: JSONValue]
}

/// What the host sends (`parseHostFrame`). Unknown kinds are kept as `.unknown` and ignored: newer
/// hosts add kinds, and a client that fails on them would reconnect forever.
public enum HostFrame: Equatable, Sendable {
    case hello(HostHello)
    /// `response` is `{type:"<type>_result", requestId, ok, error, errorCode?, …}`.
    case reply(id: Int, response: JSONValue)
    /// One committed batch; `nil` removes the key. Sent to every client, the writer included.
    case storage(changes: [String: JSONValue?])
    /// The host's Anki index changed (its known/learning words).
    case wordStatus(revision: Int)
    case ping
    case bye(reason: String?)
    case unknown(kind: String)

    public init(json: String) throws(HachidoriError) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), let kind = value["kind"]?.string else {
            throw .malformed("a frame without a kind")
        }
        switch kind {
        case "hello":
            self = .hello(HostHello(
                protocolVersion: value["protocol"]?.int ?? 0,
                version: value["version"]?.string ?? "",
                name: value["name"]?.string ?? "",
                dictionaryCount: value["dictionaryCount"]?.int ?? 0,
                capabilities: value["capabilities"]?.array?.compactMap(\.string) ?? [],
                snapshot: value["snapshot"]?.object ?? [:]))
        case "reply":
            guard let id = value["id"]?.int, let response = value["response"] else { throw .malformed("a reply without an id") }
            self = .reply(id: id, response: response)
        case "storage":
            let changes = value["changes"]?.object ?? [:]
            self = .storage(changes: changes.mapValues { value -> JSONValue? in value == .null ? nil : value })
        case "word-status":
            self = .wordStatus(revision: value["revision"]?.int ?? 0)
        case "ping":
            self = .ping
        case "bye":
            self = .bye(reason: value["reason"]?.string)
        default:
            self = .unknown(kind: kind)
        }
    }
}

public enum HachidoriError: Error, Equatable, Sendable, LocalizedError {
    /// No link within the connect timeout (the host is off, unreachable or has no hosting browser).
    case notLinked
    /// The request went out but no reply came in time.
    case timedOut
    /// The link dropped after the request was sent: the host may or may not have applied it.
    /// Hachidori never retries these, and neither do we.
    case outcomeUnknown
    /// The host answered `ok: false`.
    case host(message: String, code: String?)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notLinked: "Hachidori isn't reachable."
        case .timedOut: "Hachidori didn't answer in time."
        case .outcomeUnknown: "The link to Hachidori dropped before it answered."
        case .host(let message, _): message
        case .malformed(let what): "Hachidori sent \(what)."
        }
    }
}
