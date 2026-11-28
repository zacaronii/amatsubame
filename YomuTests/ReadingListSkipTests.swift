import Foundation
import Testing
@testable import Yomu

/// The line under a reading list's offer naming what was passed over.
@MainActor @Suite struct ReadingListSkipTests {
    @Test func countsEachReasonInAFixedOrder() {
        #expect(ReadingListSkip.summary([]) == nil)
        #expect(ReadingListSkip.summary([ReadingListSkip.pdf]) == "skipped 1 PDF")
        #expect(ReadingListSkip.summary([ReadingListSkip.hiddenLibrary, ReadingListSkip.pdf, ReadingListSkip.hiddenLibrary])
                == "skipped 1 PDF · 2 in hidden libraries")
        #expect(ReadingListSkip.summary([ReadingListSkip.unknownLibrary, ReadingListSkip.images, ReadingListSkip.images])
                == "skipped 2 image folders · 1 in a library you can't read here")
    }
}
