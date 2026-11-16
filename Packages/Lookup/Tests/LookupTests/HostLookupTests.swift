import Core
import Foundation
import HachidoriKit
@testable import Lookup
import Synchronization
import Testing

/// A Hachidori relay and host in memory: hello with `options`, and answers to `hd_lookup`
/// (one result only the host has) and `hd_lookup_stats_record` (count 9).
final class ScriptedHost: SharingTransport {
    let options: JSONValue
    let lookups = Mutex(0)
    let records = Mutex(0)

    init(options: JSONValue) {
        self.options = options
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
        case "hd_lookup_stats_record":
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
                         "capabilities": [], "snapshot": ["options": host.options]])
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
    func linked(_ service: LookupService, options: JSONValue = [:]) async throws -> ScriptedHost {
        let host = ScriptedHost(options: options)
        let connection = HostConnection(link: HachidoriLink(url: URL(string: "ws://host.example:8771/link")!, clientName: "Tests",
                                                            clientVersion: "0", transport: host))
        service.host = connection
        connection.start()
        for _ in 0..<200 where !service.followsHost { try await Task.sleep(for: .milliseconds(10)) }
        try #require(service.followsHost)
        return host
    }

    @Test func linkedLookupsUseTheHostAndItsCounts() async throws {
        let service = try await LookupServiceTests().makeService()
        let host = try await linked(service)
        let page = await service.lookup(text: "映画を見る", utf16Offset: 0)
        #expect(page.results.first?.glossaries.first?.dictionary == "Host Dictionary")
        #expect(page.lookupCount == 9, "the host's count")
        #expect(try service.counts.count(term: "映画", reading: "えいが") == 0, "nothing counted locally")
        #expect(host.lookups.withLock { $0 } == 1)

        let search = await service.search("映画")
        #expect(search.results.first?.glossaries.first?.dictionary == "Host Dictionary")
        #expect(await service.recordSearch(search) == 9)
        #expect(host.records.withLock { $0 } == 2)
        service.host = nil
    }

    @Test func theHostsPopupSettingsApplyWhileLinked() async throws {
        let service = try await LookupServiceTests().makeService()
        _ = try await linked(service, options: ["revision": 3, "showCompactDefinitionSummary": true, "popupOpacityPercent": 40,
                                                "showLookupCounts": false])
        #expect(service.popupSettings.showCompactDefinitionSummary)
        #expect(service.popupSettings.backgroundOpacityPercent == 40)
        #expect(!service.showsLookupCounts)
        #expect(await service.lookup(text: "映画", utf16Offset: 0).lookupCount == nil, "the host doesn't count")
        #expect(service.storedPopupSettings.backgroundOpacityPercent == 85, "our own settings are kept")
        #expect(service.popupSettings.backgroundBlurPercent == 50, "the host has no blur setting: ours applies")

        service.host = nil
        #expect(service.popupSettings.backgroundOpacityPercent == 85)
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
