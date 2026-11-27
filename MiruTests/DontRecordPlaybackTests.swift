import AppCommon
import Core
import Foundation
import JellyfinKit
@testable import Miru
import Testing

/// Spike (never merged): Settings ▸ Test ▸ "Don't record playback" keeps a player out of Stats and
/// Jellyfin, for the battery comparison.
@MainActor @Suite struct DontRecordPlaybackTests {
    let item = JellyfinItem(id: "E1", name: "Episode 1", type: "Episode")

    @Test func playbackIsRecordedNormally() throws {
        let environment = PlayerEnvironment.preview()
        let model = PlaybackModel(session: PlaybackSession(itemId: "E1", title: "Episode 1"), environment: environment)
        model.recordForTests(item, seconds: 30, position: 120)
        #expect(try environment.common.activity.sessions(kind: .watching).count == 1)
        #expect(try environment.common.outbox.waitingCounts()[.jellyfinProgress] == 1)
    }

    @Test func nothingIsRecordedWithTheSwitchOn() throws {
        let environment = PlayerEnvironment.preview()
        environment.recordsPlayback = false
        let model = PlaybackModel(session: PlaybackSession(itemId: "E1", title: "Episode 1"), environment: environment)
        model.recordForTests(item, seconds: 30, position: 120)
        model.close()
        #expect(try environment.common.activity.sessions(kind: .watching).isEmpty, "no Stats")
        #expect(try environment.common.outbox.waitingCounts().isEmpty, "nothing for Jellyfin")
        #expect(try environment.watchProgress.progress(itemId: "E1") == nil, "the resume point stays")
    }

    @Test func theSwitchHoldsForAPlayerThatAlreadyOpened() throws {
        let environment = PlayerEnvironment.preview()
        environment.recordsPlayback = false
        let model = PlaybackModel(session: PlaybackSession(itemId: "E1", title: "Episode 1"), environment: environment)
        environment.recordsPlayback = true
        model.recordForTests(item, seconds: 30, position: 120)
        #expect(try environment.common.activity.sessions(kind: .watching).isEmpty)
    }

    @Test func aNewEnvironmentRecords() {
        #expect(PlayerEnvironment.preview().recordsPlayback, "back on after a relaunch")
    }
}
