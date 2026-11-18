import Core
import Foundation
import Testing

@Suite struct WordStatusStoreTests {
    @Test func marksAndClearsWithoutAHost() throws {
        let store = WordStatusStore(database: try AppDatabase.inMemory())
        try store.set(.known, for: " 猫 ", host: false)
        try store.set(.ignored, for: "犬", host: false)
        #expect(try store.statuses() == ["猫": .known, "犬": .ignored])
        try store.set(nil, for: "猫", host: false)
        #expect(try store.statuses() == ["犬": .ignored])
        #expect(try store.pendingHost().isEmpty)
    }

    @Test func addsKnownWordsFromALIst() throws {
        let store = WordStatusStore(database: try AppDatabase.inMemory())
        try store.set(.ignored, for: "犬", host: false)
        #expect(try store.addKnown(["猫", "犬", "", "猫"], host: false) == 2)
        #expect(try store.statuses() == ["猫": .known, "犬": .known])
    }

    /// Changes wait for the host; a cleared word keeps its row until the host has it.
    @Test func changesWaitForTheHost() throws {
        let store = WordStatusStore(database: try AppDatabase.inMemory())
        try store.set(.known, for: "猫", host: true)
        try store.set(.known, for: "犬", host: true)
        try store.set(nil, for: "犬", host: true)
        #expect(try store.statuses() == ["猫": .known])
        let pending = try store.pendingHost()
        #expect(Set(pending.map(\.headword)) == ["猫", "犬"])
        for record in pending { try store.sentToHost(record) }
        #expect(try store.pendingHost().isEmpty)
        #expect(try store.statuses() == ["猫": .known])
    }

    @Test func aChangeMadeWhileSendingStaysPending() throws {
        let store = WordStatusStore(database: try AppDatabase.inMemory())
        try store.set(.known, for: "猫", host: true, at: Date(timeIntervalSince1970: 1_000))
        let sending = try #require(try store.pendingHost().first)
        try store.set(.ignored, for: "猫", host: true, at: Date(timeIntervalSince1970: 2_000))
        try store.sentToHost(sending)
        #expect(try store.pendingHost().map(\.status) == [.ignored])
    }

    /// The host's list wins, except over changes it hasn't had yet.
    @Test func adoptsTheHostsList() throws {
        let store = WordStatusStore(database: try AppDatabase.inMemory())
        try store.set(.known, for: "猫", host: false)
        try store.set(.known, for: "鳥", host: false)
        try store.set(.ignored, for: "魚", host: true)
        #expect(try store.adoptHost(known: ["犬", "鳥"], ignored: ["猫"]))
        #expect(try store.statuses() == ["猫": .ignored, "犬": .known, "鳥": .known, "魚": .ignored])
        #expect(try !store.adoptHost(known: ["犬", "鳥"], ignored: ["猫"]), "nothing new")
        try store.adoptHost(known: [], ignored: [])
        #expect(try store.statuses() == ["魚": .ignored], "only the change the host hasn't had")
    }

    @Test func turningTheHostOnSendsEverything() throws {
        let store = WordStatusStore(database: try AppDatabase.inMemory())
        try store.set(.known, for: "猫", host: false)
        try store.sendAllToHost()
        #expect(try store.pendingHost().map(\.headword) == ["猫"])
        try store.set(nil, for: "猫", host: true)
        try store.forgetHost()
        #expect(try store.pendingHost().isEmpty)
        #expect(try store.statuses().isEmpty)
    }

    @Test func queuesOneJobPerWord() throws {
        let outbox = OutboxStore(database: try AppDatabase.inMemory())
        try outbox.queueHostWordStatus("猫")
        try outbox.queueHostWordStatus("猫 ")
        try outbox.queueHostWordStatus("犬")
        #expect(try outbox.jobs(states: [.pending]).count == 2)
    }
}
