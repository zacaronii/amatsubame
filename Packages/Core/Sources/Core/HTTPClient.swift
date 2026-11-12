import Foundation

/// The single seam between API clients and the network. `URLSession` is the
/// production transport; tests substitute a stub that serves recorded fixtures.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse
}

public struct HTTPClient: Sendable {
    public let transport: any HTTPTransport

    /// No URL cache: some URLs carry credentials (Kavita page images take the
    /// key as a query parameter), and the app caches what it needs itself.
    public static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public init(transport: any HTTPTransport = HTTPClient.uncachedSession) {
        self.transport = transport
    }

    /// Sends a request and returns the response for any status code, mapping
    /// transport failures to `ConnectionError`.
    public func sendRaw(_ request: URLRequest) async throws(ConnectionError) -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            throw ConnectionError(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .message(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw .notThisService("Not an HTTP response")
        }
        return HTTPResponse(data: data, response: http)
    }

    /// Sends a request and throws for non-2xx status codes.
    public func send(_ request: URLRequest) async throws(ConnectionError) -> HTTPResponse {
        let result = try await sendRaw(request)
        let status = result.response.statusCode
        switch status {
        case 200..<300: return result
        case 401, 403: throw .unauthorized
        default: throw .server(status: status)
        }
    }

    public func decode<T: Decodable>(
        _ type: T.Type,
        from request: URLRequest,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws(ConnectionError) -> T {
        let result = try await send(request)
        do {
            return try decoder.decode(T.self, from: result.data)
        } catch {
            throw .unexpectedResponse(String(describing: error))
        }
    }
}

extension URLRequest {
    public static func json(
        _ method: String,
        _ url: URL,
        body: some Encodable,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)
        return request
    }

    public static func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
