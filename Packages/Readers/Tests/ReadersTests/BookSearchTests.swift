@testable import Readers
import Testing

/// Search in a book, on made-up runs.
@Suite struct BookSearchTests {
    let runs = [
        BookTextRun(section: 1, run: 0, text: "駅の前で、ねこが待っていた。"),
        BookTextRun(section: 1, run: 1, text: "ネコは眠そうだった。"),
        BookTextRun(section: 3, run: 4, text: "ＡＢＣの本とabcの本。"),
    ]

    @Test func hiraganaAndKatakanaFindEachOther() {
        let hits = BookSearch.hits("ねこ", in: runs)
        #expect(hits.map(\.match) == ["ねこ", "ネコ"])
        #expect(BookSearch.hits("ネコ", in: runs).count == 2)
    }

    @Test func caseAndWidthDoNotMatter() {
        let hits = BookSearch.hits("abc", in: runs)
        #expect(hits.map(\.match) == ["ＡＢＣ", "abc"])
        #expect(hits.map(\.section) == [3, 3])
    }

    /// Offsets are UTF-16 units into the run, as the page's script counts them.
    @Test func hitsKnowWhereTheyAre() throws {
        let hit = try #require(BookSearch.hits("待って", in: runs).first)
        #expect(hit.run == 0 && hit.offset == 8 && hit.length == 3)
        #expect(hit.before == "駅の前で、ねこが" && hit.after == "いた。")
        let emoji = [BookTextRun(section: 0, run: 0, text: "😀の後に猫")]
        #expect(BookSearch.hits("猫", in: emoji).first?.offset == 5, "an emoji is two UTF-16 units")
    }

    @Test func contextIsCutAtTheRunsEdges() throws {
        let long = String(repeating: "あ", count: 30) + "猫" + String(repeating: "い", count: 30)
        let hit = try #require(BookSearch.hits("猫", in: [BookTextRun(section: 0, run: 0, text: long)]).first)
        #expect(hit.before.count == 20 && hit.after.count == 20)
    }

    @Test func blankFindsNothingAndTheLimitHolds() {
        #expect(BookSearch.hits("  ", in: runs).isEmpty)
        let many = [BookTextRun(section: 0, run: 0, text: String(repeating: "猫", count: 40))]
        #expect(BookSearch.hits("猫", in: many, limit: 10).count == 10)
        #expect(BookSearch.hits("猫猫", in: many).count == 20, "matches don't overlap")
    }
}
