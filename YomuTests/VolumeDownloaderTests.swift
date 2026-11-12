import Core
import Foundation
import Testing
@testable import Yomu

@Suite struct VolumeDownloaderTests {
    /// connection problems wait and retry; only real errors fail a download.
    @Test func connectionProblemsAreRetriedNotFailed() {
        #expect(VolumeDownloader.isConnectionProblem(ConnectionError.timeout))
        #expect(VolumeDownloader.isConnectionProblem(ConnectionError.unreachable("offline")))
        #expect(VolumeDownloader.isConnectionProblem(ConnectionError.tls("handshake")))
        #expect(VolumeDownloader.isConnectionProblem(ConnectionError.server(status: 502)))
        #expect(VolumeDownloader.isConnectionProblem(URLError(.notConnectedToInternet)))
        #expect(!VolumeDownloader.isConnectionProblem(ConnectionError.server(status: 404)))
        #expect(!VolumeDownloader.isConnectionProblem(ConnectionError.unauthorized))
        #expect(!VolumeDownloader.isConnectionProblem(CocoaError(.fileWriteOutOfSpace)))
    }
}
