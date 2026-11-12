import Core
import SwiftUI

/// Opens the book in Yomu, read-along at the place being heard. Kiku can't see which books
/// Yomu has paired (their databases are separate), so it's offered on every book and Yomu
/// explains when one isn't paired. The time travels in the link, so it works offline too.
struct ReadInYomuButton: View {
    let entry: EpisodeEntry
    @Environment(KikuEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Read in Yomu", systemImage: "book") {
            Task {
                let time = await environment.placeForYomu(entry)
                var link = URLComponents()
                link.scheme = "amatsubame-yomu"
                link.host = "read-along"
                link.queryItems = [URLQueryItem(name: "item", value: entry.itemId),
                                   URLQueryItem(name: "t", value: String(format: "%.1f", time))]
                guard let url = link.url else { return }
                openURL(url) { accepted in environment.yomuMissing = !accepted }
            }
        }
        .accessibilityIdentifier("book.readInYomu")
    }
}

extension View {
    /// Shown where Read in Yomu was tapped (the root, or the player above it).
    func yomuMissingAlert(_ environment: KikuEnvironment, inPlayer: Bool) -> some View {
        let shown = Binding(get: { environment.yomuMissing && environment.showsPlayer == inPlayer },
                            set: { if !$0 { environment.yomuMissing = false } })
        return alert("Yomu Isn't Installed", isPresented: shown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Read-along happens in Yomu, the reader app.")
        }
    }
}

extension KikuEnvironment {
    /// Where the book is: if it's playing, pause and save that place, and give the outbox a
    /// moment to tell Audiobookshelf.
    func placeForYomu(_ entry: EpisodeEntry) async -> Double {
        if let playback, playback.key == entry.id {
            if playback.audio.isPlaying { playback.audio.pause() }
            playback.saveProgress(force: true)
            // Up to three seconds for the progress to reach Audiobookshelf (none of it if offline:
            // Yomu gets the time from the link either way).
            for _ in 0..<30 {
                let waiting = (try? common.outbox.jobs(states: [.pending, .inFlight])) ?? []
                if !waiting.contains(where: { $0.kind == .audiobookshelfProgress && $0.nextAttemptAt <= .now }) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return playback.audio.currentTime
        }
        let local = try? listenProgress.progress(itemId: entry.id)
        return LocalWatchProgress.resumePosition(local: local, server: entry.progress?.currentTime, serverDate: entry.progress?.updatedAt)
    }
}
