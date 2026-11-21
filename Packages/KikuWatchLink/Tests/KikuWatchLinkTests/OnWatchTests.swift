import Foundation
@testable import KikuWatchLink
import Testing

@Suite struct OnWatchTests {
    let added = Date(timeIntervalSince1970: 1_800_000_000)

    func episode(_ id: String = "ep", size: Int64? = 52_000_000) -> WatchItem {
        WatchItem(itemId: "show", episodeId: id, ino: "123", fileExtension: "mp3", title: "#48 梅雨の楽しみ方",
                  subtitle: "週末のんびり雑談室", duration: 1800, size: size, addedAt: added)
    }

    /// A JWT whose payload says `exp`, as Audiobookshelf's access tokens do.
    func jwt(expiring date: Date) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": date.timeIntervalSince1970, "type": "access"])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(encoded).signature"
    }

    @Test func anItemIsKeyedAndNamedLikeKikusDownloads() {
        #expect(episode().key == "show/ep")
        #expect(episode().fileName == "show-ep.mp3")
        #expect(episode().downloadPath == "api/items/show/file/123")
        let book = WatchItem(itemId: "book", episodeId: "", ino: "9", fileExtension: "m4b", title: "坊っちゃん",
                             subtitle: "夏目漱石", duration: 20000, addedAt: added)
        #expect(book.key == "book")
        #expect(book.fileName == "book.m4b")
    }

    @Test func theRequestCarriesTheToken() {
        let access = WatchAccess(server: URL(string: "https://abs.example.com/base")!, token: "key", isAPIKey: true)
        let request = access.request(for: episode())
        #expect(request.url?.absoluteString == "https://abs.example.com/base/api/items/show/file/123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    }

    @Test func anAccessTokenRunsOutButAnAPIKeyDoesnt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hour = WatchAccess(server: URL(string: "https://abs.example.com")!, token: jwt(expiring: now.addingTimeInterval(3600)), isAPIKey: false)
        #expect(hour.expiry == now.addingTimeInterval(3600))
        #expect(hour.lasts(at: now))
        // Five minutes left isn't enough to start a download on.
        #expect(!hour.lasts(at: now.addingTimeInterval(3300)))
        let key = WatchAccess(server: hour.server, token: hour.token, isAPIKey: true)
        #expect(key.expiry == nil)
        #expect(key.lasts(at: now.addingTimeInterval(1_000_000)))
    }

    @Test func theLibraryAndStateTravelTogether() {
        let library = WatchLibrary(items: [episode()], access: WatchAccess(server: URL(string: "https://abs.example.com")!, token: "t", isAPIKey: true))
        let context = WatchMessages.context(WatchState(nowPlaying: nil, liveText: true), library: library)
        #expect(WatchMessages.library(from: context) == library)
        #expect(WatchMessages.state(from: context)?.liveText == true)
        // Before anything was sent, there's no library at all (not an empty one).
        #expect(WatchMessages.library(from: WatchMessages.context(WatchState(nowPlaying: nil))) == nil)
    }

    @Test func thePhonesPlacesTravelWithTheList() throws {
        let library = WatchLibrary(items: [episode()], places: ["show/ep": WatchPlace(position: 312, updatedAt: added)])
        #expect(WatchMessages.library(from: WatchMessages.context(WatchState(nowPlaying: nil), library: library))?.places["show/ep"]?.position == 312)
        // A list from before places decodes with none.
        let old = try JSONSerialization.data(withJSONObject: ["items": []])
        #expect(try JSONDecoder().decode(WatchLibrary.self, from: old).places.isEmpty)
    }

    @Test func theInventoryAndRemovalsRoundTrip() {
        let inventory = WatchInventory(items: ["show/ep": WatchItemStatus(state: .ready, bytesDone: 52_000_000)],
                                       freeBytes: 8_000_000_000, updatedAt: added)
        #expect(WatchMessages.inventory(from: WatchMessages.context(inventory)) == inventory)
        #expect(WatchMessages.removedKey(from: WatchMessages.userInfo(removed: "show/ep")) == "show/ep")
        #expect(WatchMessages.removedKey(from: WatchMessages.userInfo(WatchQueuedMark(itemId: "a", episodeId: "", title: "", subtitle: "", position: 0, markedAt: added))) == nil)
        let reply = WatchReply(access: WatchAccess(server: URL(string: "https://abs.example.com")!, token: "t", isAPIKey: false),
                               state: WatchState(nowPlaying: nil))
        #expect(WatchMessages.reply(from: WatchMessages.message(reply)) == reply)
        #expect(WatchMessages.command(from: WatchMessages.message(WatchCommand.freshAccess)) == .freshAccess)
    }

    @Test func listeningGrowsUntilAGapOrAnotherItem() {
        var stretch = WatchListening(id: "s1", item: episode(), position: 100, rate: 1.25, at: added)
        stretch.add(60, at: 175, rate: 1.25, on: added.addingTimeInterval(60))
        #expect(stretch.seconds == 60 && stretch.startPosition == 100 && stretch.endPosition == 175)
        #expect(stretch.continues("show/ep", at: added.addingTimeInterval(60 + 299)))
        #expect(!stretch.continues("show/ep", at: added.addingTimeInterval(60 + 301)))
        #expect(!stretch.continues("show/other", at: added.addingTimeInterval(61)))
        stretch.add(5, at: 1800, rate: 1.25, on: added.addingTimeInterval(70), finished: true)
        #expect(stretch.finished && stretch.endedAt == added.addingTimeInterval(70))
        let sent = WatchMessages.userInfo(listening: [stretch])
        #expect(WatchMessages.listening(from: sent) == [stretch])
        #expect(WatchMessages.listening(from: WatchMessages.userInfo(removed: "x")) == nil)
        let library = WatchLibrary(acknowledged: ["s1": stretch.endedAt])
        #expect(WatchMessages.library(from: WatchMessages.context(WatchState(nowPlaying: nil), library: library))?.acknowledged["s1"] == stretch.endedAt)
    }

    @Test func sendNowMarksTheItemAndNamesTheFile() throws {
        var item = episode()
        #expect(!item.fromPhone)
        item.fromPhone = true
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(WatchItem.self, from: data).fromPhone)
        // An item saved before Send Now decodes as downloaded by the watch.
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["fromPhone"] = nil
        #expect(try !JSONDecoder().decode(WatchItem.self, from: JSONSerialization.data(withJSONObject: old)).fromPhone)
        #expect(WatchMessages.fileKey(from: WatchMessages.metadata(fileFor: "show/ep")) == "show/ep")
        #expect(WatchMessages.fileKey(from: nil) == nil)
    }

    @Test func liveTextCommandsNameTheirEpisode() {
        #expect(WatchCommand.lookUp(key: "show/ep", line: 3, character: 1).lineKey == "show/ep")
        #expect(WatchCommand.transcriptPart(id: "show/ep#abc", from: 0).lineKey == "show/ep")
        #expect(WatchCommand.replayLine(key: "show/ep", line: 3).lineKey == nil)
        #expect(WatchCommand.togglePlay.lineKey == nil)
    }

    @Test func aRuleSaysWhyAnItemIsThere() throws {
        var item = episode()
        #expect(item.reason == nil)
        item.reason = .ahead
        #expect(try JSONDecoder().decode(WatchItem.self, from: JSONEncoder().encode(item)).reason == .ahead)
    }

    @Test func statusText() {
        #expect(WatchItemStatus(state: .waiting).text == "Waiting")
        #expect(WatchItemStatus(state: .waiting, message: "Waiting for your iPhone").text == "Waiting for your iPhone")
        #expect(WatchItemStatus(state: .downloading, bytesDone: 40, bytesTotal: 100).text == "40%")
        #expect(WatchItemStatus(state: .downloading).text == "Downloading")
        #expect(WatchItemStatus(state: .failed, message: "No space").text == "Failed: No space")
        #expect(WatchItemStatus(state: .ready).text == "Ready")
    }

    @Test func smallProgressIsntWorthSending() {
        func inventory(_ done: Int64, free: Int64 = 8_000_000_000) -> WatchInventory {
            WatchInventory(items: ["k": WatchItemStatus(state: .downloading, bytesDone: done, bytesTotal: 100)], freeBytes: free, updatedAt: added)
        }
        #expect(inventory(41).matches(inventory(48)))
        #expect(!inventory(41).matches(inventory(51)))
        #expect(!inventory(41).matches(inventory(41, free: 7_000_000_000)))
        var finished = inventory(100)
        finished.items["k"]?.state = .ready
        #expect(!inventory(100).matches(finished))
        #expect(!inventory(41).matches(WatchInventory(updatedAt: added)))
    }
}
