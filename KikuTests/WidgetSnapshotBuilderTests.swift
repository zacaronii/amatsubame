import AudiobookshelfKit
import Core
import Foundation
@testable import Kiku
import KikuIntents
import Testing

/// What the widgets get: the current episode (playing, else the last played) and the next two
/// (Up Next, else Continue Listening).
@MainActor @Suite struct WidgetSnapshotBuilderTests {
    func entry(_ id: String, listened: Double? = nil) -> EpisodeEntry {
        let json = #"{"id":"\#(id)","libraryItemId":"show","title":"第\#(id)回","duration":600,"audioFile":{"ino":"1","duration":600}}"#
        let episode = try! JSONDecoder().decode(AudiobookshelfEpisode.self, from: Data(json.utf8))
        let progress = listened.map {
            try! JSONDecoder().decode(AudiobookshelfProgress.self, from: Data(#"{"id":"p\#(id)","libraryItemId":"show","episodeId":"\#(id)","duration":600,"currentTime":\#($0),"progress":0,"isFinished":false,"lastUpdate":0}"#.utf8))
        }
        return EpisodeEntry(episode: episode, showTitle: "番組", progress: progress)
    }

    @Test func playingWithUpNext() {
        let up = [UpNextItem(itemId: "s2", episodeId: "x", title: "次", showTitle: "別"),
                  UpNextItem(itemId: "s3", episodeId: "y", title: "その次", showTitle: "別"),
                  UpNextItem(itemId: "s4", episodeId: "z", title: "三つ目", showTitle: "別")]
        let snapshot = KikuWidgetPublisher.snapshot(playing: (entry("1"), 150, true), lastPlayed: nil, upNext: up, continueListening: [])
        #expect(snapshot.current?.title == "第1回" && snapshot.current?.timeLeft == 450 && snapshot.current?.fraction == 0.25)
        #expect(snapshot.isPlaying && snapshot.nextTitle == "Up Next" && snapshot.next.map(\.title) == ["次", "その次"])
    }

    @Test func nothingPlayingShowsTheLastAndContinueListening() {
        let last = entry("1", listened: 300), other = entry("2", listened: 60), third = entry("3", listened: 30)
        let snapshot = KikuWidgetPublisher.snapshot(playing: nil, lastPlayed: last, upNext: [], continueListening: [last, other, third])
        #expect(snapshot.current?.key == last.id && snapshot.current?.fraction == 0.5 && !snapshot.isPlaying)
        #expect(snapshot.nextTitle == "Continue Listening" && snapshot.next.map(\.key) == [other.id, third.id], "not the current one again")
        let empty = KikuWidgetPublisher.snapshot(playing: nil, lastPlayed: nil, upNext: [], continueListening: [])
        #expect(empty.current == nil && empty.next.isEmpty && empty.nextTitle.isEmpty)
    }
}
