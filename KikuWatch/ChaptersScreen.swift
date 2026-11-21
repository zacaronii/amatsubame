import KikuWatchLink
import SwiftUI

/// The playing book's or episode's chapters (docs/KIKU_PLAN.md milestone 6), in either mode:
/// Previous and Next, then the list. Choosing one plays on from its start.
struct ChaptersScreen: View {
    @Environment(WatchSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let playing = session.nowPlaying, let chapters = playing.chapters {
            let current = playing.chapterIndex(at: .now)
            ScrollViewReader { proxy in
                List {
                    HStack {
                        Button { go(to: playing.previousChapterStart(at: .now), of: playing) } label: {
                            Image(systemName: "backward.end.fill").frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel("Previous Chapter")
                        Button { go(to: playing.nextChapterStart(at: .now), of: playing) } label: {
                            Image(systemName: "forward.end.fill").frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel("Next Chapter")
                        .disabled(playing.nextChapterStart(at: .now) == nil)
                    }
                    .buttonStyle(.bordered)
                    .listRowBackground(Color.clear)
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        Button { go(to: chapter.start, of: playing) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chapter.title).font(.footnote).fontWeight(index == current ? .semibold : .regular).lineLimit(2)
                                    Text(chapter.start.watchClock).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if index == current { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint) }
                            }
                        }
                        .id(index)
                    }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
            .navigationTitle("Chapters")
        } else {
            Text("No chapters").foregroundStyle(.secondary).navigationTitle("Chapters")
        }
    }

    private func go(to time: Double?, of playing: WatchNowPlaying) {
        guard let time else { return }
        session.send(.seek(key: playing.key, to: time))
        dismiss()
    }
}

/// The playback speed, for whichever plays (the phone's speeds).
struct SpeedScreen: View {
    @Environment(WatchSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rate = session.nowPlaying?.rate ?? 1
        List(WatchNowPlaying.speeds, id: \.self) { speed in
            Button {
                session.send(.setRate(speed))
                dismiss()
            } label: {
                HStack {
                    Text(WatchNowPlaying.speedText(speed)).monospacedDigit()
                    Spacer()
                    if abs(rate - speed) < 0.01 { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
        }
        .navigationTitle("Speed")
    }
}
