import XCTest

/// Read-along against Kavita, Audiobookshelf and Kaku servers: pairs an EPUB series' volume with its audiobook,
/// prepares it, and reads along. Needs the Kavita env plus `UITEST_ABS_URL/KEY`,
/// `UITEST_KAKU_URL/TOKEN`, `UITEST_READALONG_LIBRARY` and `UITEST_READALONG_SERIES` (and
/// `UITEST_READALONG_ITEM`, the audiobook's id, to check Kiku's Read in Yomu link;
/// `UITEST_READALONG_CHARACTERS`, the book's character count, to check it exactly).
/// In memory, and nothing is sent: progress stays on the simulator.
final class ReadAlongUITests: XCTestCase {
    private var app: XCUIApplication!
    private var library = ""
    private var series = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let names = ["UITEST_KAVITA_URL", "UITEST_KAVITA_KEY", "UITEST_ABS_URL", "UITEST_ABS_KEY", "UITEST_KAKU_URL", "UITEST_KAKU_TOKEN"]
        guard names.allSatisfy({ env[$0] != nil }), let library = env["UITEST_READALONG_LIBRARY"], let series = env["UITEST_READALONG_SERIES"] else {
            throw XCTSkip("Set the TEST_RUNNER_UITEST_ Kavita, ABS and Kaku variables and UITEST_READALONG_LIBRARY/SERIES.")
        }
        self.library = library
        self.series = series
        app = XCUIApplication()
        for name in names { app.launchEnvironment[name] = env[name] }
        if let dictionaries = env["UITEST_DICTIONARY_ZIPS"] { app.launchEnvironment["UITEST_DICTIONARY_ZIPS"] = dictionaries }
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens the series and pairs its volume with the audiobook.
    private func pair() {
        app.launch()
        let libraryRow = app.buttons[library].firstMatch
        XCTAssertTrue(libraryRow.waitForExistence(timeout: 20), "library \(library) not listed")
        for _ in 0..<6 where !libraryRow.isHittable { app.swipeUp() }
        libraryRow.tap()
        let tile = app.buttons["series.\(series)"].firstMatch
        // The grid is lazy: scroll until the series is there.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'series.'")).firstMatch.waitForExistence(timeout: 20))
        for _ in 0..<15 where !(tile.exists && tile.isHittable) { app.swipeUp() }
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "series \(series) not found")
        tile.tap()

        // Pair from the Read-Along section.
        let menu = app.buttons["readAlong.menu"].firstMatch
        for _ in 0..<6 where !menu.isHittable { app.swipeUp() }
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["Pair with an Audiobook…"].tap()
        let book = app.buttons["pairing.book"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "no audiobooks listed")
        book.tap()
        // Getting ready: the book's text read, the transcript fetched and matched.
        let ready = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'of sentences matched'")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 300), "not ready")
        shot("paired")
        let status = ready.label
        let attachment = XCTAttachment(string: status)
        attachment.name = "status"
        attachment.lifetime = .keepAlways
        add(attachment)

    }

    func testPairPrepareAndReadAlong() {
        pair()
        // Read along: playing moves the highlight (and turns pages).
        for _ in 0..<6 where !app.buttons["series.continue"].isHittable { app.swipeDown() }
        app.buttons["series.continue"].firstMatch.tap()
        // The audio bar shows with the reader's controls: a tap in the bottom margin (never text).
        let page = app.descendants(matching: .any)["book.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the book opened")
        sleep(3)
        XCTAssertFalse(app.buttons["readAlong.previous"].exists, "the bar hides with the controls")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        let play = app.buttons["readAlong.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 60), "no read-along bar")
        sleep(3)
        shot("reader-paused")
        // Queries on a book page are slow (its text is in the accessibility tree): sample a few times.
        let time = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+:[0-9:]+'")).firstMatch
        play.tap()
        sleep(2)
        var samples: [(playing: Bool, time: String)] = []
        for _ in 0..<3 {
            samples.append((play.value as? String == "playing", time.label))
            shot("reader-playing-\(samples.count)")
        }
        let log = XCTAttachment(string: samples.map { "\($0.playing) \($0.time)" }.joined(separator: "\n"))
        log.name = "samples"
        log.lifetime = .keepAlways
        add(log)
        XCTAssertTrue(samples.allSatisfy(\.playing), "plays")
        XCTAssertNotEqual(samples.first?.time, samples.last?.time, "the time moves")
        play.tap()

        // The headphones button turns read-along off (the bar goes, plain reading) and on again.
        let readAlong = app.buttons["reader.readAlong"]
        XCTAssertTrue(readAlong.waitForExistence(timeout: 20), "the read-along switch")
        readAlong.tap()
        XCTAssertTrue(play.waitForNonExistence(timeout: 30), "off hides the bar")
        XCTAssertEqual(readAlong.value as? String, "off")
        shot("reader-read-along-off")
        readAlong.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 30), "on brings the bar back")

        // Kiku's Read in Yomu: the link reopens the volume at its time (half an hour in).
        guard let item = ProcessInfo.processInfo.environment["UITEST_READALONG_ITEM"] else { return }
        // Through the system, as Kiku does (`app.open` relaunches the app, losing its in-memory data).
        XCUIDevice.shared.system.open(URL(string: "amatsubame-yomu://read-along?item=\(item)&t=1800")!)
        sleep(5)
        let moved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '30:0'")).firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 30), "the link opened the book at 30:00")
        shot("reader-from-link")
    }

    /// The reader keeps its place: turning pages, read-along off and on, a reopen.
    func testReaderKeepsItsPlace() {
        pair()
        for _ in 0..<6 where !app.buttons["series.continue"].isHittable { app.swipeDown() }
        app.buttons["series.continue"].firstMatch.tap()
        let page = app.descendants(matching: .any)["book.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the book opened")
        sleep(3)
        var log: [String] = []
        var places: [String] = []
        func note(_ step: String) {
            // The progress line shows with the controls: a tap in the bottom margin shows them.
            let progress = app.staticTexts["book.progress"].firstMatch
            if !progress.exists { page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap() }
            _ = progress.waitForExistence(timeout: 10)
            let place = "\(page.value as? String ?? "?") · \(progress.exists ? progress.label : "?")"
            places.append(place)
            log.append("\(step): \(place)")
            shot(step)
        }
        note("opened")
        // Forward in a vertical book: a swipe to the right (controls hidden first).
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        sleep(1)
        for _ in 0..<6 { page.swipeRight() }
        sleep(2)
        note("turned")
        // The controls hiding and showing again leave the text where it is.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.985)).tap()
        sleep(2)
        note("controls")
        let readAlong = app.buttons["reader.readAlong"]
        XCTAssertTrue(readAlong.waitForExistence(timeout: 20))
        readAlong.tap()
        sleep(3)
        note("off")
        readAlong.tap()
        sleep(8)
        note("on")
        app.buttons["reader.close"].firstMatch.tap()
        sleep(2)
        for _ in 0..<6 where !app.buttons["series.continue"].isHittable { app.swipeDown() }
        app.buttons["series.continue"].firstMatch.tap()
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        sleep(5)
        note("reopened")
        let attachment = XCTAttachment(string: log.joined(separator: "\n"))
        attachment.name = "places"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("=== PLACES\n" + log.joined(separator: "\n"))
        // Counted as Hoshi Reader counts (letters only): the same total for the same EPUB.
        // `UITEST_READALONG_CHARACTERS` (formatted as shown, e.g. "12,345") checks the exact total; otherwise just its format.
        if let total = ProcessInfo.processInfo.environment["UITEST_READALONG_CHARACTERS"] {
            XCTAssertTrue(places[0].contains("/ \(total) 字"), places[0])
        } else {
            XCTAssertNotNil(places[0].range(of: #"/ [0-9,]+ 字"#, options: .regularExpression), places[0])
        }
        // From the pages turned on: the same page and count throughout.
        XCTAssertNotEqual(places[0], places[1], "the pages turned")
        XCTAssertEqual(Set(places.dropFirst()).count, 1, log.joined(separator: "\n"))
    }

    /// Settings ▸ Character Counts counts every Japanese book's characters from Kavita's text.
    func testCountCharacters() {
        app.launch()
        app.tabBars.buttons["Settings"].firstMatch.tap()
        let link = app.buttons["Character Counts"].firstMatch
        for _ in 0..<6 where !link.isHittable { app.swipeUp() }
        link.tap()
        let start = app.buttons["counts.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 120), "the survey offers a count")
        shot("counts-survey")
        start.tap()
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 120), "counting")
        // The rows keep up while counting; Stop keeps what's counted and says so.
        let oneCounted = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Counted, ' AND NOT label BEGINSWITH 'Counted, 0 '")).firstMatch
        XCTAssertTrue(oneCounted.waitForExistence(timeout: 120), "the Counted row updates as volumes finish")
        // Never past its total: "N of M volumes".
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' volumes'")).matching(NSPredicate(format: "label CONTAINS ' of '")).firstMatch
        if line.exists {
            let numbers = line.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if numbers.count >= 2 { XCTAssertLessThanOrEqual(numbers[0], numbers[1], line.label) }
        }
        stop.tap()
        let stopped = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Stopped'")).firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 30), "Stopped, not an error")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'cancel'")).firstMatch.exists)
        shot("counts-stopped")
        start.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 120), "counting again")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Zero'")).firstMatch.exists, "no Zero kB")
        XCTAssertTrue(stop.waitForNonExistence(timeout: 900), "finished")
        sleep(5)
        // Nothing left to count: the survey no longer offers the button.
        XCTAssertTrue(start.waitForNonExistence(timeout: 120), "every volume counted")
        XCTAssertTrue(app.staticTexts["Not counted, 0 volumes"].firstMatch.waitForExistence(timeout: 30), "none left, none counted twice")
        shot("counts-done")
    }
}
