import Testing
@testable import Miru

/// Watching Now through dropped polls: the last list stays until three fail in a row.
@MainActor @Suite struct PollFailuresTests {
    @Test func theListGoesOnlyAfterThreeFailuresInARow() {
        var failures = PollFailures()
        var clears: [Bool] = []
        clears.append(failures.failed())
        clears.append(failures.failed())
        failures.succeeded()   // a poll that worked starts the count again
        clears.append(failures.failed())
        clears.append(failures.failed())
        clears.append(failures.failed())   // the third in a row clears it
        #expect(clears == [false, false, false, false, true])
    }
}

/// Lines' search: "No Results" waits for the search of what's typed (it flashed on the first
/// character while the 200 ms debounce ran, with the empty results of the empty query).
@MainActor @Suite struct LinesNoResultsTests {
    @Test func noResultsOnlyForTheTextSearched() {
        #expect(!LinesView.showsNoResults(true, searched: "", query: "猫"), "typed, not searched yet")
        #expect(!LinesView.showsNoResults(true, searched: nil, query: "猫"))
        #expect(LinesView.showsNoResults(true, searched: "鯨", query: "鯨"))
        #expect(!LinesView.showsNoResults(false, searched: "猫", query: "猫"))
    }
}
