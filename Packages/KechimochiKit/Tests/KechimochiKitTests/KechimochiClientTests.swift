import Core
import CoreTestSupport
import Foundation
@testable import KechimochiKit
import Testing

/// Fixtures in the shape kechimochi 0.3.3 returns, with made-up activity.
@Suite struct KechimochiClientTests {
    let base = URL(string: "https://kechimochi.example.ts.net")!

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    @Test func snapshotReadsTheSummaryAndHeatmap() async throws {
        let transport = StubTransport(routes: ["/api/dashboard/snapshot": (200, try fixture("snapshot.json"))])
        let snapshot = try await KechimochiClient(baseURL: base, http: HTTPClient(transport: transport)).snapshot(today: "2026-11-07", year: 2026)
        #expect(snapshot.summary.totalMinutes == 475)
        #expect(snapshot.summary.loggedDays == 16 && snapshot.summary.currentStreak == 8 && snapshot.summary.maxStreak == 8)
        #expect(snapshot.summary.firstActivityDate == "2026-10-20")
        #expect(snapshot.summary.dailyAverageMinutes == 30)
        #expect(snapshot.summary.activityTotals.map(\.label) == ["Listening", "Watching", "Reading", "Playing"])
        #expect(snapshot.heatmap.year == 2026 && snapshot.heatmap.days.count == 16)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        let body = try request.jsonBody()
        #expect(body["today"] as? String == "2026-11-07")
        #expect(body["heatmap_year"] as? Int == 2026)
    }

    @Test func heatmapForAnotherYear() async throws {
        let transport = StubTransport(routes: ["/api/dashboard/heatmap-year": (200, try fixture("heatmap-year.json"))])
        let heatmap = try await KechimochiClient(baseURL: base, http: HTTPClient(transport: transport)).heatmap(year: 2026)
        #expect(heatmap.days.first == KechimochiDay(date: "2026-10-20", totalMinutes: 12))
        #expect(try transport.requests.first?.jsonBody()["year"] as? Int == 2026)
    }

    @Test func version() async throws {
        let transport = StubTransport(routes: ["/api/version": (200, try fixture("version.json"))])
        #expect(try await KechimochiClient(baseURL: base, http: HTTPClient(transport: transport)).version() == "web-0.3.3")
        #expect(transport.requests.first?.httpMethod == "GET")
    }

    /// kechimochi has no login: only reads are possible from here.
    @Test func onlyReadsCanBeMade() {
        #expect(KechimochiClient.allowedPaths == ["/api/version", "/api/dashboard/snapshot", "/api/dashboard/heatmap-year"])
        #expect(!KechimochiClient.allowedPaths.contains { $0.contains("reset") || $0.contains("import") || $0.contains("logs") })
    }
}
