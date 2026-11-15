import Foundation

/// One open `/link` connection: text frames in and out.
public protocol SharingSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame; throws once the connection closes.
    func receive() async throws -> String
    func close()
}

/// Opens connections (a fake in tests).
public protocol SharingTransport: Sendable {
    func connect(to url: URL, origin: String) async throws -> any SharingSocket
}

/// `URLSessionWebSocketTask`, with the Origin header the relay checks.
public struct URLSessionSharingTransport: SharingTransport {
    /// How long the opening handshake may take (an unreachable address otherwise waits a minute).
    public var connectTimeout: TimeInterval

    public init(connectTimeout: TimeInterval = 5) {
        self.connectTimeout = connectTimeout
    }

    public func connect(to url: URL, origin: String) async throws -> any SharingSocket {
        var request = URLRequest(url: url, timeoutInterval: connectTimeout)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let task = URLSession.shared.webSocketTask(with: request)
        // Styles and dictionary images come as single frames well over the 1 MB default.
        task.maximumMessageSize = 64 << 20
        task.resume()
        return Socket(task: task)
    }

    struct Socket: SharingSocket {
        let task: URLSessionWebSocketTask

        func send(_ text: String) async throws {
            try await task.send(.string(text))
        }

        func receive() async throws -> String {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
}
