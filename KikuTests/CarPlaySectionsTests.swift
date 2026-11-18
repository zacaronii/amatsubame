import AudiobookshelfKit
import Foundation
@testable import Kiku
import Testing

@MainActor @Suite struct CarPlaySectionsTests {
    func entry(_ id: String, show: String = "show", duration: Double = 600, listened: Double? = nil) -> EpisodeEntry {
        let json = #"{"id":"\#(id)","libraryItemId":"\#(show)","title":"Episode \#(id)","duration":\#(duration),"audioFile":{"ino":"1","duration":\#(duration)}}"#
        let episode = try! JSONDecoder().decode(AudiobookshelfEpisode.self, from: Data(json.utf8))
        let progress = listened.map {
            try! JSONDecoder().decode(AudiobookshelfProgress.self, from: Data(#"{"id":"p\#(id)","libraryItemId":"\#(show)","episodeId":"\#(id)","duration":\#(duration),"currentTime":\#($0),"progress":0,"isFinished":false,"lastUpdate":0}"#.utf8))
        }
        return EpisodeEntry(episode: episode, showTitle: "週末雑談室", progress: progress)
    }

    @Test func listenNowHasContinueThenNewEpisodes() {
        let started = entry("a", listened: 150)
        let sections = CarPlaySections.listenNow(continueListening: [started], newEpisodes: [entry("b"), started],
                                                 playingKey: started.id)
        #expect(sections.map(\.title) == ["Continue", "New Episodes"])
        let row = sections[0].rows[0]
        #expect(row.progress == 0.25)
        #expect(row.isPlaying)
        #expect(row.detail == "週末雑談室 · \(Double(450).lengthText) left")
        #expect(row.action == .play(started))
        // What's in Continue isn't listed again.
        #expect(sections[1].rows.map(\.title) == ["Episode b"])
        #expect(sections[1].rows[0].progress == nil)
    }

    @Test func emptySectionsAreLeftOut() {
        #expect(CarPlaySections.listenNow(continueListening: [], newEpisodes: [], playingKey: nil).isEmpty)
        #expect(CarPlaySections.listenNow(continueListening: [], newEpisodes: [entry("b")], playingKey: nil).map(\.title) == ["New Episodes"])
    }

    @Test func librariesSkipHiddenOnesAndEndWithDownloaded() {
        let libraries = try! JSONDecoder().decode([AudiobookshelfLibrary].self, from: Data(#"""
            [{"id":"1","name":"ポッドキャスト","mediaType":"podcast"},{"id":"2","name":"Audiobooks","mediaType":"book"},
             {"id":"3","name":"オーディオブック","mediaType":"book"}]
            """#.utf8))
        let sections = CarPlaySections.libraries(libraries, hidden: ["2"], downloadedCount: 3)
        #expect(sections.flatMap(\.rows).map(\.title) == ["ポッドキャスト", "オーディオブック", "Downloaded"])
        #expect(sections[0].rows[1].detail == "Audiobooks")
        #expect(sections.last?.rows.last?.action == .openDownloaded)
        #expect(sections.last?.rows.last?.detail == "3 on this iPhone")
        // Without a server, Downloaded is still there.
        #expect(CarPlaySections.libraries([], hidden: [], downloadedCount: 0).flatMap(\.rows).map(\.title) == ["Downloaded"])
    }

    @Test func episodesSayWhatsLeft() {
        let rows = CarPlaySections.episodes([entry("a", listened: 300), entry("b")], playingKey: nil, showsShow: true)[0].rows
        #expect(rows[0].detail == "週末雑談室 · \(Double(300).lengthText) left")
        #expect(rows[1].detail == "週末雑談室 · \(Double(600).lengthText)")
    }

    @Test func longListsAreCutWithANote() {
        let rows = (0..<30).map { CarPlayRow(title: "\($0)", action: .none) }
        let sections = [CarPlaySection(title: "A", rows: Array(rows.prefix(5))), CarPlaySection(title: "B", rows: rows)]
        let limited = CarPlaySections.limited(sections, maxItems: 12, maxSections: 10)
        #expect(limited.map(\.rows.count) == [5, 7])
        #expect(limited[1].rows.last?.title == "24 more on your iPhone")
        #expect(limited.flatMap(\.rows).count == 12)
        // A section that doesn't fit at all is dropped; so are sections past the limit.
        #expect(CarPlaySections.limited(sections, maxItems: 5, maxSections: 10).map(\.title) == ["A"])
        #expect(CarPlaySections.limited(sections, maxItems: 100, maxSections: 1).map(\.title) == ["A"])
        #expect(CarPlaySections.limited(sections, maxItems: 100, maxSections: 10) == sections)
    }

    @Test func chaptersMarkTheCurrentOne() throws {
        let chapters = try JSONDecoder().decode([AudiobookshelfChapter].self, from: Data(
            #"[{"id":0,"start":0,"end":20,"title":"第一章"},{"id":1,"start":20,"end":40,"title":"第二章"}]"#.utf8))
        let rows = CarPlaySections.chapters(chapters, current: chapters[1])[0].rows
        #expect(rows.map(\.isPlaying) == [false, true])
        #expect(rows[1].action == .seek(20))
    }

    @Test func speedButtonStepsThroughThePlayersSpeeds() {
        #expect(CarPlaySpeeds.next(after: 1, speeds: [0.75, 1, 1.5, 2]) == 1.5)
        #expect(CarPlaySpeeds.next(after: 2, speeds: [0.75, 1, 1.5, 2]) == 0.75)
        // A speed between steps goes to the next one up.
        #expect(CarPlaySpeeds.next(after: 1.2, speeds: [0.75, 1, 1.5, 2]) == 1.5)
    }
}
