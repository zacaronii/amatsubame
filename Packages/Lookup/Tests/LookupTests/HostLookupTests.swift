import Core
import Foundation
import Dictionary
import DictionaryTestSupport
import HachidoriKit
@testable import Lookup
import Synchronization
import Testing

/// A Hachidori relay and host in memory: hello with `options`, and answers to `hd_lookup`
/// (one result only the host has) and `hd_lookup_stats_read` (count 9).
final class ScriptedHost: SharingTransport {
    let options: JSONValue
    /// More of the hello's snapshot (beside `options`).
    let snapshot: [String: JSONValue]
    let lookups = Mutex(0)
    let records = Mutex(0)

    init(options: JSONValue, snapshot: [String: JSONValue] = [:]) {
        self.options = options
        self.snapshot = snapshot
    }

    func connect(to url: URL, origin: String) async throws -> any SharingSocket {
        Socket(host: self)
    }

    func reply(to message: JSONValue) -> JSONValue? {
        switch message["type"]?.string {
        case "hd_lookup":
            lookups.withLock { $0 += 1 }
            return ["ok": true, "generation": 1, "dictionaryCount": 1, "results": [[
                "matched": "映画", "deinflected": "映画", "preprocessorSteps": 0,
                "term": ["expression": "映画", "reading": "えいが", "rules": "n", "score": 0,
                         "glossaries": [["dictionary": "Host Dictionary", "glossary": #"["a film on the host"]"#]]],
            ]]]
        case "hd_lookup_stats_read":
            records.withLock { $0 += 1 }
            return ["ok": true, "statistics": ["term": "映画", "reading": "えいが", "lookupCount": 9]]
        default:
            return nil
        }
    }

    final class Socket: SharingSocket {
        let host: ScriptedHost
        let inbox = Mutex<(frames: [String], waiter: CheckedContinuation<String, Error>?)>(([], nil))

        init(host: ScriptedHost) {
            self.host = host
        }

        func send(_ text: String) async throws {
            let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            switch frame["kind"]?.string {
            case "hello":
                deliver(["kind": "hello", "protocol": 1, "version": "test", "name": "Test host", "dictionaryCount": 1,
                         "capabilities": [], "snapshot": .object(host.snapshot.merging(["options": host.options]) { $1 })])
            case "request":
                if let id = frame["id"], let message = frame["message"], let response = host.reply(to: message) {
                    deliver(["kind": "reply", "id": id, "response": response])
                }
            default:
                break
            }
        }

        func deliver(_ frame: JSONValue) {
            let text = String(decoding: try! JSONEncoder().encode(frame), as: UTF8.self)
            inbox.withLock { inbox in
                if let waiter = inbox.waiter {
                    inbox.waiter = nil
                    waiter.resume(returning: text)
                } else {
                    inbox.frames.append(text)
                }
            }
        }

        func receive() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                inbox.withLock { inbox in
                    if inbox.frames.isEmpty { inbox.waiter = continuation } else { continuation.resume(returning: inbox.frames.removeFirst()) }
                }
            }
        }

        func close() {
            inbox.withLock { inbox in
                inbox.waiter?.resume(throwing: URLError(.networkConnectionLost))
                inbox.waiter = nil
            }
        }
    }
}

@Suite @MainActor struct HostLookupTests {
    func linked(_ service: LookupService, options: JSONValue = [:], snapshot: [String: JSONValue] = [:]) async throws -> ScriptedHost {
        let host = ScriptedHost(options: options, snapshot: snapshot)
        let connection = HostConnection(link: HachidoriLink(url: URL(string: "ws://host.example:8771/link")!, clientName: "Tests",
                                                            clientVersion: "0", transport: host))
        service.host = connection
        service.looksUpOnHost = true
        connection.start()
        for _ in 0..<200 where !service.followsHost { try await Task.sleep(for: .milliseconds(10)) }
        try #require(service.followsHost)
        return host
    }

    @Test func linkedLookupsUseTheHostAndItsCounts() async throws {
        let service = try await LookupServiceTests().makeService()
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        service.hostOutbox = (outbox, {})
        let host = try await linked(service)
        let page = await service.lookup(text: "映画を見る", utf16Offset: 0)
        #expect(page.results.first?.glossaries.first?.dictionary == "Host Dictionary")
        #expect(page.lookupCount == 10, "the host's 9 and this one, still queued")
        #expect(try outbox.queuedHostLookupCount(term: "映画", reading: "えいが") == 1)
        #expect(try service.counts.count(term: "映画", reading: "えいが") == 10, "kept for offline")
        #expect(host.lookups.withLock { $0 } == 1)

        let search = await service.search("映画")
        #expect(search.results.first?.glossaries.first?.dictionary == "Host Dictionary")
        #expect(await service.recordSearch(search) == 11)
        #expect(host.records.withLock { $0 } == 2)
        service.host = nil
    }

    /// The Mac's lookups go to the host, which hasn't the names of the series open here: the
    /// local names dictionary's hits join in, a longer one first, a tie after the host's word.
    @Test func linkedLookupsKeepTheLocalCharacterNames() async throws {
        let service = try await LookupServiceTests().makeService()
        var names = TestDictionaryBuilder(title: NameRanking.characterNamesTitle)
        names.terms = [.init("映画太郎", "えいがたろう", glossary: ["a made-up character"]), .init("映画", "えいが", glossary: ["a one-word name"])]
        try await service.library.importDictionary(at: try names.write())
        let host = try await linked(service)
        let page = await service.lookup(text: "映画太郎です", utf16Offset: 0)
        #expect(page.results.map { "\($0.expression) \($0.glossaries.first?.dictionary ?? "")" }
            == ["映画太郎 Character Names", "映画 Host Dictionary", "映画 Character Names"])
        #expect(host.lookups.withLock { $0 } == 1)
        service.host = nil
    }

    /// iPhone and iPad look up locally while linked; counts and settings are still the host's.
    @Test func linkedWithoutHostLookups() async throws {
        let service = try await LookupServiceTests().makeService()
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        service.hostOutbox = (outbox, {})
        let host = try await linked(service)
        service.looksUpOnHost = false
        let page = await service.lookup(text: "映画", utf16Offset: 0)
        #expect(page.results.first?.glossaries.first?.dictionary == "Terms")
        #expect(page.lookupCount == 10)
        #expect(host.lookups.withLock { $0 } == 0)
        service.host = nil
    }

    @Test func theHostsPopupSettingsApplyWhileLinkedAndAreKept() async throws {
        let service = try await LookupServiceTests().makeService()
        _ = try await linked(service, options: ["revision": 3, "showCompactDefinitionSummary": true, "popupOpacityPercent": 40,
                                                "showLookupCounts": false])
        #expect(service.popupSettings.showCompactDefinitionSummary)
        #expect(service.popupSettings.backgroundOpacityPercent == 40)
        #expect(!service.showsLookupCounts)
        #expect(await service.lookup(text: "映画", utf16Offset: 0).lookupCount == nil, "the host doesn't count")
        #expect(service.storedPopupSettings.backgroundOpacityPercent == 40, "kept for when the host is away")

        service.host = nil
        #expect(service.popupSettings.backgroundOpacityPercent == 40)
        #expect(!service.showsLookupCounts)
    }

    @Test func withoutTheHostLookupsStayLocal() async throws {
        let service = try await LookupServiceTests().makeService()
        let connection = HostConnection(link: HachidoriLink(url: URL(string: "ws://host.example:8771/link")!, clientName: "Tests",
                                                            clientVersion: "0", transport: Unreachable()))
        service.host = connection
        connection.start()
        let page = await service.lookup(text: "映画", utf16Offset: 0)
        #expect(page.results.first?.glossaries.first?.dictionary == "Terms")
        #expect(page.lookupCount == 1)
        service.host = nil
    }

    struct Unreachable: SharingTransport {
        func connect(to url: URL, origin: String) async throws -> any SharingSocket { throw URLError(.cannotConnectToHost) }
    }
}
