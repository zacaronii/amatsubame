import Foundation

/// Every failure an API client can surface, phrased for the settings screens
/// and classified for the outbox's retry policy.
public enum ConnectionError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case unreachable(String)
    case timeout
    case tls(String)
    case unauthorized
    case server(status: Int)
    case notThisService(String)
    case unexpectedResponse(String)
    case cancelled
    case message(String)

    public init(_ error: URLError) {
        switch error.code {
        case .timedOut:
            self = .timeout
        case .cancelled:
            self = .cancelled
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            self = .tls(error.localizedDescription)
        case .badURL, .unsupportedURL:
            self = .invalidURL
        default:
            self = .unreachable(error.localizedDescription)
        }
    }

    /// Whether retrying later might succeed without anyone changing anything.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .timeout, .cancelled: true
        case .server(let status): status >= 500 || status == 408 || status == 429
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The server URL isn't valid. Use http:// or https:// followed by a host."
        case .unreachable(let detail): "Couldn't reach the server. \(detail)"
        case .timeout: "The server took too long to respond."
        case .tls(let detail): "Secure connection failed. \(detail)"
        case .unauthorized: "The server rejected the credentials."
        case .server(let status): "The server returned HTTP \(status)."
        case .notThisService(let detail): "This doesn't look like the right kind of server. \(detail)"
        case .unexpectedResponse(let detail): "The server sent a response the app didn't understand. \(detail)"
        case .cancelled: "The request was cancelled."
        case .message(let text): text
        }
    }
}

extension Error {
    /// A request cancelled on purpose (a view's task restarting or going away): not worth showing.
    public var isCancellation: Bool {
        if self is CancellationError { return true }
        if let error = self as? ConnectionError { return error == .cancelled }
        if let error = self as? URLError { return error.code == .cancelled }
        return false
    }
}
