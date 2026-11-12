import Foundation
import Testing
@testable import Miru

/// Lines stays a history: only episodes of one show watched back to back are grouped.
@MainActor @Suite struct LinesRunsTests {
    func entry(_ id: String, _ show: String) -> LinesHistoryModel.Entry {
        LinesHistoryModel.Entry(id: id, show: show, detail: "", imageTag: nil, lastPlayed: nil, hasJapanese: true, isSaved: false, progress: nil)
    }

    @Test func groupsOnlyBackToBackEpisodes() {
        let history = [entry("1", "A"), entry("2", "A"), entry("3", "B"), entry("4", "A"), entry("5", "A"), entry("6", "A")]
        #expect(LinesHistoryModel.runs(history).map { $0.map(\.id) } == [["1", "2"], ["3"], ["4", "5", "6"]])
        #expect(LinesHistoryModel.runs([]).isEmpty)
    }
}
