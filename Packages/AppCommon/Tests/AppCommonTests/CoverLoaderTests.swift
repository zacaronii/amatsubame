@testable import AppCommon
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Answers cover requests with a programmable status, headers and body, and keeps each request.
final class CoverStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    nonisolated(unsafe) static var reply = Reply(status: 404)
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let reply = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverStubProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized) struct CoverLoaderTests {
    let cache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0)
    let session = CoverStubProtocol.session

    /// A different URL per test: `CoverLoader` remembers what it checked this launch.
    func request() -> URLRequest {
        URLRequest(url: URL(string: "https://covers.example/series-cover?seriesId=\(UUID().uuidString)")!)
    }

    /// A tiny PNG of one colour.
    func png(_ red: CGFloat) -> Data {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func load(_ request: URLRequest) async throws -> Data? {
        try await CoverLoader.data(for: request, session: session, cache: cache)
    }

    /// Before covers were checked, a 404 was cached and the placeholder stayed for good.
    @Test func aMissingCoverIsntCached() async throws {
        let request = request()
        CoverStubProtocol.reply = .init(status: 404, body: Data(#"{"status": 404}"#.utf8))
        #expect(try await load(request) == nil)
        #expect(cache.cachedResponse(for: request) == nil)
    }

    @Test func anUnchangedCoverIsCheckedOnceAndKept() async throws {
        let request = request()
        let red = png(1)
        CoverStubProtocol.reply = .init(status: 200, headers: ["Last-Modified": "Thu, 12 Nov 2026 18:38:25 GMT"], body: red)
        #expect(try await load(request) == red)

        // Next launch: checked with If-Modified-Since, the server says not modified.
        CoverLoader.forgetChecks()
        CoverStubProtocol.requests = []
        CoverStubProtocol.reply = .init(status: 304)
        #expect(try await load(request) == red)
        #expect(CoverStubProtocol.requests.first?.value(forHTTPHeaderField: "If-Modified-Since") == "Thu, 12 Nov 2026 18:38:25 GMT")

        // Checked already this launch: no request at all.
        CoverStubProtocol.requests = []
        #expect(try await load(request) == red)
        #expect(CoverStubProtocol.requests.isEmpty)
    }

    @Test func aChangedCoverReplacesTheCachedOne() async throws {
        let request = request()
        CoverStubProtocol.reply = .init(status: 200, headers: ["Last-Modified": "Wed, 11 Nov 2026 10:00:00 GMT"], body: png(1))
        _ = try await load(request)

        CoverLoader.forgetChecks()
        let blue = png(0)
        CoverStubProtocol.reply = .init(status: 200, headers: ["Last-Modified": "Thu, 12 Nov 2026 18:38:25 GMT"], body: blue)
        #expect(try await load(request) == blue)
        #expect(cache.cachedResponse(for: request)?.data == blue)
    }

    @Test func aServerErrorKeepsTheCachedCover() async throws {
        let request = request()
        let red = png(1)
        CoverStubProtocol.reply = .init(status: 200, body: red)
        _ = try await load(request)
        CoverLoader.forgetChecks()
        CoverStubProtocol.reply = .init(status: 500)
        #expect(try await load(request) == red)
    }
}
