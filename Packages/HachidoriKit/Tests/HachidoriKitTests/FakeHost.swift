import Foundation
import HachidoriKit
import Synchronization
import Testing

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

func fixtureValue(_ name: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(fixture(name).utf8))
}

func json(_ value: JSONValue) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

/// A relay with a host behind it: answers the client's hello with `hello`, and each request with
/// `respond(message)` (nil leaves it unanswered).
final class FakeHost: SharingTransport {
    struct State {
        var hello: String?
        var refuses = false
        var origins: [String] = []
        var sockets: [FakeSocket] = []
        var respond: @Sendable (JSONValue) -> JSONValue? = { _ in nil }
    }

    let state: Mutex<State>

    init(hello: String?) {
        state = Mutex(State(hello: hello))
    }

    var connections: Int { state.withLock { $0.sockets.count } }
    var origins: [String] { state.withLock { $0.origins } }
    var socket: FakeSocket? { state.withLock { $0.sockets.last } }

    func respond(_ handler: @escaping @Sendable (JSONValue) -> JSONValue?) {
        state.withLock { $0.respond = handler }
    }

    func refuse(_ refuses: Bool) {
        state.withLock { $0.refuses = refuses }
    }

    func connect(to url: URL, origin: String) async throws -> any SharingSocket {
        let socket = try state.withLock { state in
            state.origins.append(origin)
            if state.refuses { throw URLError(.cannotConnectToHost) }
            let socket = FakeSocket(host: self)
            state.sockets.append(socket)
            return socket
        }
        return socket
    }

    func received(_ text: String, on socket: FakeSocket) {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return }
        switch frame["kind"]?.string {
        case "hello":
            if let hello = state.withLock({ $0.hello }) { socket.deliver(hello) }
        case "request":
            let respond = state.withLock { $0.respond }
            if let id = frame["id"], let message = frame["message"], let response = respond(message) {
                socket.deliver(json(["kind": "reply", "id": id, "response": response]))
            }
        default:
            break
        }
    }
}

final class FakeSocket: SharingSocket {
    struct State {
        var inbox: [String] = []
        var waiter: CheckedContinuation<String, Error>?
        var closed = false
        var sent: [String] = []
        /// False: the connection is gone without anyone noticing (airplane mode).
        var answersPings = true
    }

    weak let host: FakeHost?
    let state = Mutex(State())

    init(host: FakeHost) {
        self.host = host
    }

    var sent: [String] { state.withLock { $0.sent } }

    func send(_ text: String) async throws {
        try state.withLock { state in
            if state.closed { throw URLError(.networkConnectionLost) }
            state.sent.append(text)
        }
        host?.received(text, on: self)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if !state.inbox.isEmpty {
                    continuation.resume(returning: state.inbox.removeFirst())
                } else if state.closed {
                    continuation.resume(throwing: URLError(.networkConnectionLost))
                } else {
                    state.waiter = continuation
                }
            }
        }
    }

    /// The host sends a frame.
    func deliver(_ text: String) {
        state.withLock { state in
            if let waiter = state.waiter {
                state.waiter = nil
                waiter.resume(returning: text)
            } else {
                state.inbox.append(text)
            }
        }
    }

    func ping(timeout: Duration) async -> Bool {
        state.withLock { $0.answersPings && !$0.closed }
    }

    /// The connection drops.
    func close() {
        state.withLock { state in
            state.closed = true
            state.waiter?.resume(throwing: URLError(.networkConnectionLost))
            state.waiter = nil
        }
    }
}
