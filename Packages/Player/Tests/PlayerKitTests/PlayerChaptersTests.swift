@testable import PlayerKit
import Testing

/// Chapters for the scrubber and previous/next chapter (made-up times).
@Suite struct PlayerChaptersTests {
    // A prologue and the opening both at 0 (as Jellyfin lists some files), then two parts and
    // an ending, in a 24-minute episode; one past the end is dropped.
    let chapters = PlayerChapters([(0, "Prologue"), (0, "Opening"), (90, "Part A"), (720, "Part B"), (1350, "Ending"), (1500, "Past")],
                                  duration: 1440)

    @Test func oneChapterPerStartWithinTheVideo() {
        #expect(chapters.chapters.map(\.start) == [0, 90, 720, 1350])
        #expect(chapters.chapters.first?.name == "Opening", "the later of two at the same start")
    }

    @Test func whichChapterIsPlaying() {
        #expect(chapters.name(at: 0) == "Opening")
        #expect(chapters.name(at: 89.9) == "Opening")
        #expect(chapters.name(at: 90) == "Part A")
        #expect(chapters.name(at: 1439) == "Ending")
    }

    @Test func previousGoesToTheStartThenTheOneBefore() {
        #expect(chapters.previousStart(from: 800) == 720, "well into Part B: its start")
        #expect(chapters.previousStart(from: 722) == 90, "just after its start: Part A")
        #expect(chapters.previousStart(from: 1) == 0, "the first: its start")
    }

    @Test func nextGoesToTheFollowingStart() {
        #expect(chapters.nextStart(from: 0) == 90)
        #expect(chapters.nextStart(from: 700) == 720)
        #expect(chapters.nextStart(from: 1400) == nil, "the last has none")
    }

    @Test func marksSitAtTheStartsAfterTheFirst() {
        #expect(chapters.marks(duration: 1440) == [90.0 / 1440, 720.0 / 1440, 1350.0 / 1440])
    }

    @Test func fewerThanTwoChaptersIsNone() {
        let one = PlayerChapters([(0, "Chapter 01")], duration: 1440)
        #expect(one.isEmpty)
        #expect(one.marks(duration: 1440).isEmpty)
        #expect(one.nextStart(from: 0) == nil && one.previousStart(from: 10) == nil)
        #expect(PlayerChapters([(0, "A"), (0, "B")], duration: 100).isEmpty, "two at the same start are one")
    }
}
