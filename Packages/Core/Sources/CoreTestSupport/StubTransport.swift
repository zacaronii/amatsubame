import Core
import Foundation
import Synchronization

/// An `HTTPTransport` for tests: each request is passed to `handler`, and every
/// request is recorded so tests can assert on method, headers and body.
public final class StubTransport: HTTPTransport {
    public typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private let handler: Handler
    private let recorded = Mutex<[URLRequest]>([])

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Routes by URL path (ignoring any base-path prefix by matching the suffix).
    public convenience init(routes: [String: (Int, Data)]) {
        self.init { request in
            let path = request.url?.path() ?? ""
            for (suffix, response) in routes where path.hasSuffix(suffix) {
                return response
            }
            return (404, Data())
        }
    }

    public var requests: [URLRequest] { recorded.withLock { $0 } }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorded.withLock { $0.append(request) }
        let (status, data) = try handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

public enum Fixture {
    /// Loads `Fixtures/<name>` from a test bundle (`Bundle.module` of the test target).
    public static func data(_ name: String, in bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/\(name)"])
        }
        return try Data(contentsOf: url)
    }
}

extension URLRequest {
    /// The body as a JSON object, for asserting on what a client sent.
    public func jsonBody() throws -> [String: Any] {
        let data = httpBody ?? Data()
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
