@testable import AppCommon
import Core
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// A progress handler an app might register (e.g. Kavita or Jellyfin).
struct RecordingHandler: OutboxHandler {
    let kind = OutboxJobKind.kavitaProgress
    func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {}
}

@MainActor @Suite struct CommonEnvironmentTests {
    func environment(sendsCards: Bool, handlers: [any OutboxHandler] = []) throws -> CommonEnvironment {
        let temp = FileManager.default.temporaryDirectory.appending(path: "common-\(UUID().uuidString)")
        return CommonEnvironment(
            database: try AppDatabase.inMemory(), secrets: InMemorySecretStore(),
            mediaDirectory: temp.appending(path: "Media"), dictionaryDirectory: temp.appending(path: "Dictionaries"),
            sendsCards: sendsCards, appHandlers: { _ in handlers }
        )
    }

    @Test func appHandlersAndCardsAreRegistered() async throws {
        let common = try environment(sendsCards: true, handlers: [RecordingHandler()])
        try common.outbox.enqueue(Data("{}".utf8), kind: .kavitaProgress)
        let report = await common.worker.drain()
        #expect(report.sent == 1, "the app's handler sends its jobs")
        #expect(common.lookup.mining === common.mining, "lookups offer mining")
    }

    /// Signed in to a demo server, its writes stay on the device (and aren't "waiting to
    /// sync"). Leaving it, by signing out or by signing in to your own server in its place,
    /// discards them: none is ever sent, to the demo or to your server.
    @Test(arguments: [false, true]) func aDemoServersWritesAreHeldThenDiscarded(switchesToOwnServer: Bool) async throws {
        let common = try environment(sendsCards: true, handlers: [RecordingHandler()])
        // Its clean-up empties the downloads folder DictionaryUpdaterTests use meanwhile.
        common.dictionaryUpdater.isEnabled = false
        let started = Task { await common.start() }
        defer { started.cancel() }
        try common.accounts.save(ServerAccount(kind: .kavita, baseURL: URL(string: "https://kavita-demo.example.com")!, isDemo: true))
        for _ in 0..<50 where common.heldKinds.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(common.heldKinds.contains(.kavitaProgress) && common.heldKinds.contains(.kavitaReadingList))
        #expect(!common.heldKinds.contains(.ankiNote) && !common.heldKinds.contains(.jellyfinProgress))
        try common.outbox.enqueue(Data("{}".utf8), kind: .kavitaProgress)
        #expect(await common.worker.drain().sent == 0, "held on the device")

        if switchesToOwnServer {
            try common.accounts.save(ServerAccount(kind: .kavita, baseURL: URL(string: "https://kavita.example.ts.net")!))
        } else {
            try common.accounts.delete(.kavita)
        }
        for _ in 0..<50 where !common.heldKinds.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(common.heldKinds.isEmpty)
        #expect(try common.outbox.jobs(states: [.pending, .failed, .inFlight]).isEmpty, "the demo's jobs are gone")
        #expect(await common.worker.drain().sent == 0, "and never sent")
    }

    @Test func statsReadTheSeriesFromOlderCardsSources() {
        #expect(StatsModel.title(miscInfo: "鉄の時計 — Volume 1, p. 9") == "鉄の時計")
        #expect(StatsModel.title(miscInfo: "&quot;Midnight Bridge&quot; — S1E6 · 6:21") == "\"Midnight Bridge\"")
        #expect(StatsModel.title(miscInfo: "No source") == nil)
        #expect(StatsModel.dates(noteIds: [1_793_449_611_446]).first == Date(timeIntervalSince1970: 1_793_449_611.446))
    }

    @Test func todayCountsOnlyToday() throws {
        let common = try environment(sendsCards: false)
        let subject = ActivitySubject(kind: .reading, seriesKey: "1", seriesTitle: "そら", itemKey: "9")
        let now = Date()
        try common.activity.record(subject, at: now.addingTimeInterval(-86_400 * 2), characters: 500)
        try common.activity.record(subject, at: now.addingTimeInterval(-60), characters: 300)
        try common.activity.record(subject, at: now, characters: 100)
        try common.activity.recordLookup(at: now)
        try common.activity.saveAnkiNoteIds([Int64(now.timeIntervalSince1970 * 1000), 1_700_000_000_000])
        let today = TodaySummary.load(kind: .reading, environment: common, now: now)
        #expect(today.characters == 400 && today.seconds == 60)
        #expect(today.lookups == 1 && today.cards == 1 && today.streak == 1)
    }

    @Test func coverTintIsTheAverageColour() throws {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let color = try #require(CoverTint.color(of: image))
        let resolved = color.resolve(in: EnvironmentValues())
        #expect(resolved.red > 0.9 && resolved.green < 0.1 && resolved.blue < 0.1)
    }

    @Test func cardsStayQueuedWhenNotSending() async throws {
        let common = try environment(sendsCards: false)
        try common.outbox.enqueue(Data("{}".utf8), kind: .ankiNote)
        let report = await common.worker.drain()
        #expect(report.sent == 0)
        #expect(try common.outbox.summary().pending == 1)
    }

    @Test func noAnkiClientUntilSetUp() throws {
        let common = try environment(sendsCards: true)
        #expect(common.ankiClient() == nil)
        try common.accounts.save(ServerAccount(kind: .anki, baseURL: URL(string: "http://anki.example.ts.net:8765")!, serverName: "AnkiConnect"))
        #expect(common.ankiClient() != nil)
    }
}
