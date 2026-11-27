import Foundation
import Synchronization

/// One open `/link` connection: text frames in and out.
public protocol SharingSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame; throws once the connection closes.
    func receive() async throws -> String
    /// Whether the other end answers a ping within `timeout`.
    func ping(timeout: Duration) async -> Bool
    func close()
}

public extension SharingSocket {
    func ping(timeout: Duration) async -> Bool { true }
}

/// Opens connections (a fake in tests).
public protocol SharingTransport: Sendable {
    func connect(to url: URL, origin: String) async throws -> any SharingSocket
}

/// The relay answered the WebSocket handshake with an HTTP status instead of switching protocols.
public enum SharingSocketError: Error, Equatable, Sendable {
    case refused(status: Int)
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
            do {
                switch try await task.receive() {
                case .string(let text): return text
                case .data(let data): return String(decoding: data, as: UTF8.self)
                @unknown default: return ""
                }
            } catch {
                // A handshake the server turned down (a proxy's 403, a 404): say so, not just "bad response".
                if let http = task.response as? HTTPURLResponse, http.statusCode != 101 { throw SharingSocketError.refused(status: http.statusCode) }
                throw error
            }
        }

        func ping(timeout: Duration) async -> Bool {
            let answered = Mutex(false)
            return await withCheckedContinuation { continuation in
                let resume: @Sendable (Bool) -> Void = { alive in
                    guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(returning: alive)
                }
                task.sendPing { error in resume(error == nil) }
                Task {
                    try? await Task.sleep(for: timeout)
                    resume(false)
                }
            }
        }

        func close() {
            task.cancel(with: .normalClosure, reason: nil)
        }
    }
}
