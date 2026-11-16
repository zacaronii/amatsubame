import Dictionary
import Foundation
@testable import HachidoriKit
import Testing

@Suite struct FrameTests {
    @Test func helloFromAHost() throws {
        guard case .hello(let hello) = try HostFrame(json: fixture("hello")) else { Issue.record("not a hello"); return }
        #expect(hello.protocolVersion == 1)
        #expect(hello.dictionaryCount == 5)
        #expect(hello.capabilities.contains("linked-anki-v2"))
        #expect(Set(hello.snapshot.keys) == Set(SharedRecords.snapshotKeys))
    }

    @Test func otherHostFrames() throws {
        #expect(try HostFrame(json: #"{"kind":"storage","changes":{"a":1,"b":null}}"#) == .storage(changes: ["a": 1, "b": nil]))
        #expect(try HostFrame(json: #"{"kind":"word-status","revision":4}"#) == .wordStatus(revision: 4))
        #expect(try HostFrame(json: #"{"kind":"ping"}"#) == .ping)
        #expect(try HostFrame(json: #"{"kind":"bye","reason":"protocol"}"#) == .bye(reason: "protocol"))
        // Newer hosts add kinds; they must not break the link.
        #expect(try HostFrame(json: #"{"kind":"something-new","x":1}"#) == .unknown(kind: "something-new"))
        #expect(throws: HachidoriError.self) { try HostFrame(json: "[]") }
    }

    @Test func clientFrames() {
        #expect(ClientFrame.hello(version: "0.3.0", name: "Yomu").json
            == #"{"capabilities":[],"kind":"hello","name":"Yomu","protocol":1,"version":"0.3.0"}"#)
        #expect(ClientFrame.pong.json == #"{"kind":"pong"}"#)
        // Ids are integers: the host checks them with Number.isInteger.
        #expect(ClientFrame.request(id: 7, message: ["type": "hd_status", "requestId": 7]).json
            == #"{"id":7,"kind":"request","message":{"requestId":7,"type":"hd_status"}}"#)
    }
}

@Suite struct SharedRecordsTests {
    func records() throws -> SharedRecords {
        guard case .hello(let hello) = try HostFrame(json: fixture("hello")) else { throw HachidoriError.malformed("hello") }
        var records = SharedRecords()
        records.apply(snapshot: hello.snapshot)
        return records
    }

    @Test func optionsWithHachidorisDefaults() throws {
        let options = try records().options
        // Stored by the host:
        #expect(options.maxResults == 24)
        #expect(options.frequencyDictionary == "Jiten")
        #expect(options.showCompactDefinitionSummary)
        #expect(options.popupOpacityPercent == 70)
        // Not stored, so Hachidori's defaults:
        #expect(options.scanLength == 16)
        #expect(options.frequencyOrder == "auto")
        #expect(options.showLookupCounts)
        #expect(options.compactDefinitionSummaryCount == 3)
        #expect(HostOptions(nil).popupOpacityPercent == 85)
    }

    @Test func dictionariesAndWords() throws {
        let records = try records()
        #expect(records.dictionaries.map(\.title) == ["Bee's Ultimate Grammar Dictionary", "Bee's Ultimate Kanji Dictionary", "Jiten",
                                                      "Jitendex.org [2026-10-03]", "JMnedict [2026-11-13]"])
        #expect(records.dictionaries.filter { !$0.enabled }.isEmpty)
        #expect(records.wordStatus == WordStatusOverrides(revision: 3, known: ["食べる"], ignored: ["する"]))
        #expect(records.customDictionaryText.hasPrefix("食べる, たべる"))
    }

    @Test func storageChangesAndCountRows() throws {
        var records = try records()
        let generation = try #require(records.lookupStats.generation)
        let key = #"lookupStats:"\#(generation)":["食べる","たべる"]"#
        records.apply(changes: [
            "lookupStats": ["generation": .string(generation), "revision": 17],
            key: ["term": "食べる", "reading": "たべる", "lookupCount": 5, "firstLookedUpAt": 1, "lastLookedUpAt": 2],
            "wordStatusOverrides": nil,
        ])
        #expect(records.lookupStats.revision == 17)
        #expect(records.lookupCount(term: " 食べる", reading: "たべる")?.lookupCount == 5)
        #expect(records.lookupCount(term: "飲む", reading: "のむ") == nil)
        #expect(records.wordStatus == WordStatusOverrides())

        // A reset starts a new generation: the old rows no longer count.
        records.apply(changes: ["lookupStats": ["generation": "another", "revision": 18]])
        #expect(records.lookupCount(term: "食べる", reading: "たべる") == nil)
    }
}

@Suite struct HostLookupTests {
    @Test func mapsTheHostsResults() throws {
        let page = try HostLookupPage(response: fixtureValue("lookup-reply")["response"]!)
        #expect(page.generation == 7)
        #expect(page.dictionaryCount == 6)
        #expect(page.results.count == 5)
        let first = try #require(page.results.first)
        #expect(first.matched == "食べたかった")
        #expect(first.deinflected == "食べる")
        #expect(first.expression == "食べる")
        #expect(first.reading == "たべる")
        #expect(first.rules == ["v1"])
        #expect(first.score == 200)
        // Base outward, like our engine.
        #expect(first.inflections.map(\.name) == ["-たい", "-た"])
        let jitendex = try #require(first.glossaries.first)
        #expect(jitendex.dictionary == "Jitendex.org [2026-10-03]")
        #expect(jitendex.definitionTags == ["★"])
        #expect(jitendex.termTags.isEmpty)
        #expect(jitendex.json.hasPrefix("[{\"type\":"))
        #expect(first.frequencies == [FrequencyGroup(dictionary: "Jiten", values: [
            Frequency(value: 188, display: "188"), Frequency(value: 14429, display: "14429㋕"),
        ])])
    }

    @Test func pitchesAndFractionalScores() throws {
        let response: JSONValue = ["ok": true, "generation": 2, "results": [[
            "matched": "箸", "deinflected": "箸", "preprocessorSteps": 0,
            "term": ["expression": "箸", "reading": "はし", "rules": "n", "score": 1.6,
                     "pitches": [["dictionary": "Kanjium", "pitches": [["position": 1, "nasal": [], "devoice": [2]]]]]],
        ]]]
        let result = try #require(try HostLookupPage(response: response).results.first)
        #expect(result.score == 1.6, "kept as the host sent it")
        #expect(result.pitches == [PitchGroup(dictionary: "Kanjium", accents: [PitchAccent(downstep: 1, devoice: [2])])])
    }
}

@Suite struct LinkURLTests {
    @Test func fromWhatUsersType() {
        #expect(HachidoriLink.linkURL(from: "192.0.2.10")?.absoluteString == "ws://192.0.2.10:8771/link")
        #expect(HachidoriLink.linkURL(from: " host.example:9000 ")?.absoluteString == "ws://host.example:9000/link")
        #expect(HachidoriLink.linkURL(from: "http://host.example:8771")?.absoluteString == "ws://host.example:8771/link")
        #expect(HachidoriLink.linkURL(from: "ws://host.example:8771/link")?.absoluteString == "ws://host.example:8771/link")
        #expect(HachidoriLink.linkURL(from: "") == nil)
        #expect(HachidoriLink.linkURL(from: "ftp://host.example") == nil)
    }
}

@Suite struct LinkTests {
    static var fast: HachidoriLink.Timing {
        var timing = HachidoriLink.Timing()
        timing.linkWait = .milliseconds(300)
        timing.reply = .milliseconds(300)
        timing.backoffBase = .milliseconds(20)
        timing.backoffMax = .milliseconds(40)
        return timing
    }

    func link(_ host: FakeHost) -> HachidoriLink {
        HachidoriLink(url: URL(string: "ws://host.example:8771/link")!, clientName: "Yomu", clientVersion: "0.3.0",
                      transport: host, timing: Self.fast)
    }

    func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func linksAndLooksUp() async throws {
        let host = FakeHost(hello: try fixture("hello"))
        let reply = try fixtureValue("lookup-reply")["response"]!
        host.respond { message in message["type"] == "hd_lookup" ? reply : nil }
        let link = link(host)
        await link.start()
        let page = try await link.lookup("食べたかった")
        #expect(page.results.first?.expression == "食べる")
        #expect(host.origins == ["hoshi://hoshidicts"])
        guard case .linked(let name, _, _) = await link.status else { Issue.record("not linked"); return }
        #expect(name == "Hachidori Docker host")
        #expect(await link.generation == 7)

        // The hello went first; the lookup used the host's stored settings.
        let sent = try #require(host.socket?.sent)
        #expect(sent.first?.contains(#""kind":"hello""#) == true)
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(sent[1].utf8))
        #expect(request["message"]?["target"] == "hoshidicts-offscreen")
        #expect(request["message"]?["maxResults"] == 24)
        #expect(request["message"]?["scanLength"] == 16)
        #expect(request["message"]?["options"]?["frequencyDictionary"] == "Jiten")
        #expect(request["message"]?["requestId"] == request["id"])
        await link.stop()
    }

    @Test func hostErrorsAndCounts() async throws {
        let host = FakeHost(hello: try fixture("hello"))
        let error = try fixtureValue("error-reply")["response"]!
        let stats = try fixtureValue("stats-read-reply")["response"]!
        host.respond { message in
            switch message["type"]?.string {
            case "hd_lookup_stats_read": stats
            case "hd_lookup_stats_record": ["ok": true, "statistics": .null]
            default: error
            }
        }
        let link = link(host)
        await link.start()
        #expect(try await link.lookupCount(term: "食べる", reading: "たべる")?.lookupCount == 4)
        // The host has counts turned off.
        #expect(try await link.recordLookup(term: "食べる", reading: "たべる") == nil)
        await #expect(throws: HachidoriError.host(message: "Unsupported operation: hoshidicts-offscreen/hd_bogus.", code: nil)) {
            try await link.request("hoshidicts-offscreen", "hd_bogus")
        }
        await link.stop()
    }

    @Test func answersPingsAndIgnoresUnknownFrames() async throws {
        let host = FakeHost(hello: try fixture("hello"))
        let link = link(host)
        let updates = await link.updates()
        await link.start()
        await waitUntil { if case .linked = await link.status { true } else { false } }
        let socket = try #require(host.socket)
        socket.deliver(#"{"kind":"something-new"}"#)
        socket.deliver(#"{"kind":"ping"}"#)
        socket.deliver(#"{"kind":"storage","changes":{"wordStatusOverrides":{"revision":4,"known":["猫"],"ignored":[]}}}"#)
        socket.deliver(#"{"kind":"word-status","revision":9}"#)
        await waitUntil { socket.sent.contains(#"{"kind":"pong"}"#) }
        #expect(socket.sent.contains(#"{"kind":"pong"}"#))
        await waitUntil { await link.records.wordStatus.known == ["猫"] }
        #expect(await link.records.wordStatus.known == ["猫"])
        #expect(host.connections == 1)

        var seen: [HachidoriLink.Update] = []
        for await update in updates {
            seen.append(update)
            if update == .wordStatus(revision: 9) { break }
        }
        #expect(seen.contains(.records(["wordStatusOverrides"])))
        #expect(seen.contains(.records(Set(SharedRecords.snapshotKeys))))
        await link.stop()
    }

    @Test func aDroppedLinkLeavesWritesUnknownAndReconnects() async throws {
        let host = FakeHost(hello: try fixture("hello"))
        let link = link(host)
        await link.start()
        // Unanswered: the link drops while it's out.
        let write = Task { try await link.setWordStatus(.known, for: "猫") }
        await waitUntil { host.socket?.sent.count == 2 }
        host.socket?.close()
        await #expect(throws: HachidoriError.outcomeUnknown) { try await write.value }
        await waitUntil { host.connections == 2 }
        #expect(host.connections == 2)
        await waitUntil { if case .linked = await link.status { true } else { false } }
        // The new hello's snapshot replaced the mirror.
        #expect(await link.records.wordStatus.known == ["食べる"])
        await link.stop()
    }

    @Test func unansweredRequestsTimeOut() async throws {
        let host = FakeHost(hello: try fixture("hello"))
        let link = link(host)
        await link.start()
        await #expect(throws: HachidoriError.timedOut) { try await link.request("hoshidicts-offscreen", "hd_status") }
        await link.stop()
    }

    @Test func withoutAHostRequestsFailAndTheLinkKeepsTrying() async throws {
        let host = FakeHost(hello: nil)
        host.refuse(true)
        let link = link(host)
        await #expect(throws: HachidoriError.notLinked) { try await link.request("hoshidicts-offscreen", "hd_status") }
        await link.start()
        await #expect(throws: HachidoriError.notLinked) { try await link.request("hoshidicts-offscreen", "hd_status") }
        await waitUntil { host.origins.count >= 4 }
        #expect(host.origins.count >= 4)
        guard case .waiting(let delay) = await link.status else { Issue.record("not waiting"); return }
        #expect(delay <= .milliseconds(40))

        // The host comes back.
        host.state.withLock { $0.hello = try? fixture("hello") }
        host.refuse(false)
        await waitUntil { if case .linked = await link.status { true } else { false } }
        guard case .linked = await link.status else { Issue.record("never linked"); return }
        await link.stop()
        #expect(await link.status == .stopped)
    }
}

/// Against a real host, read only (no counts, no writes): `HACHIDORI_LINK_URL=ws://<host>:8771/link swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HACHIDORI_LINK_URL"] != nil))
struct LiveLinkTests {
    @Test func readsFromARealHost() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["HACHIDORI_LINK_URL"].flatMap(HachidoriLink.linkURL))
        let link = HachidoriLink(url: url, clientName: "Amatsubame tests", clientVersion: "0.3.0")
        await link.start()
        let page = try await link.lookup("食べたかった")
        #expect(page.results.first?.expression == "食べる")
        #expect(!(await link.records.dictionaries.isEmpty))
        #expect(!(try await link.styles().isEmpty))
        _ = try await link.lookupCount(term: "食べる", reading: "たべる")
        await link.stop()
    }

    /// Copies the host's smallest dictionary (read-only): list, download, unpack, look up.
    @Test func copiesADictionaryFromARealHost() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["HACHIDORI_LINK_URL"].flatMap(HachidoriLink.linkURL))
        let link = HachidoriLink(url: url, clientName: "Amatsubame tests", clientVersion: "0.3.0")
        await link.start()
        _ = try await link.lookup("食べる")
        let state = await link.records.dictionaries
        await link.stop()
        let exports = HostDictionaryExports(baseURL: try #require(HostDictionaryExports.apiURL(forLink: url)))
        let list = try await exports.list()
        #expect(Set(list.map(\.id)) == Set(state.map(\.id)), "every dictionary in dictionaryState can be exported")
        let grammar = try #require(list.first { $0.title.hasPrefix("Bee's Ultimate Grammar") }, "needs Bee's Grammar on the host")
        let work = temporaryFolder()
        try await exports.download(grammar.id, to: work.appending(path: "export.zip"))
        try HostDictionaryExports.unpack(work.appending(path: "export.zip"), into: work.appending(path: "dictionary"))
        #expect(DictionaryFormat(folder: work.appending(path: "dictionary")) != .missing)
        let engine = DictionaryEngine()
        let rejected = await engine.configure([EngineDictionary(title: grammar.title, folder: work.appending(path: "dictionary"),
                                                                hasTerms: true, hasFrequencies: false, hasPitches: false, hasKanji: false)],
                                              frequencySortTitle: nil)
        #expect(rejected.isEmpty)
        #expect(await engine.lookup("ために").first?.glossaries.first?.dictionary == grammar.title)
        try? FileManager.default.removeItem(at: work)
    }
}
