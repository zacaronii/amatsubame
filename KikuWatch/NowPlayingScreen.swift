import KikuWatchLink
import SwiftUI
import WatchKit

/// The one screen: what's playing on the iPhone, its controls and a large Mark button; or a calm
/// note when nothing is. The crown turns the iPhone's volume.
struct NowPlayingScreen: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        ZStack {
            if let playing = session.nowPlaying {
                NowPlayingControls(playing: playing)
            } else {
                NothingPlaying()
            }
            if let confirmation = session.confirmation {
                MarkedCard(confirmation: confirmation)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.confirmation)
    }
}

private struct NowPlayingControls: View {
    @Environment(WatchSession.self) private var session
    let playing: WatchNowPlaying

    var body: some View {
        // Ticks once a second while playing (watchOS slows it on its own with the wrist down).
        TimelineView(.periodic(from: .now, by: playing.isPlaying ? 1 : 60)) { context in
            VStack(spacing: 6) {
                header
                progress(at: context.date)
                controls
                Button { session.send(.mark) } label: {
                    Label("Mark", systemImage: "bookmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("watch.mark")
                if let notice = session.notice {
                    Text(notice).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Artwork(data: playing.artwork).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(playing.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(playing.chapter ?? playing.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            // Takes the crown: it turns the iPhone's volume, as in Apple's Now Playing.
            PhoneVolume().scaleEffect(0.55).frame(width: 26, height: 26)
        }
    }

    private func progress(at date: Date) -> some View {
        let position = playing.position(at: date)
        return VStack(spacing: 2) {
            ProgressView(value: playing.fraction(at: date))
            HStack {
                Text(position.watchClock)
                Spacer()
                Text("−" + max(playing.duration - position, 0).watchClock)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack {
            Button { session.send(.skipBackward) } label: {
                Image(systemName: Self.skipSymbol("gobackward", playing.skipBackward))
            }
            .accessibilityLabel("Back \(Int(playing.skipBackward)) seconds")
            Button { session.send(.togglePlay) } label: {
                Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("watch.playPause")
            Button { session.send(.skipForward) } label: {
                Image(systemName: Self.skipSymbol("goforward", playing.skipForward))
            }
            .accessibilityLabel("Forward \(Int(playing.skipForward)) seconds")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .frame(maxWidth: .infinity)
        .labelStyle(.iconOnly)
    }

    /// "gobackward.15": SF Symbols has 5–90 s in these steps; others use the plain arrow.
    static func skipSymbol(_ base: String, _ seconds: Double) -> String {
        let steps = [5, 10, 15, 30, 45, 60, 75, 90]
        let whole = Int(seconds)
        return steps.contains(whole) ? "\(base).\(whole)" : base
    }
}

private struct Artwork: View {
    let data: Data?

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .overlay {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

private struct NothingPlaying: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("KikuGlyph")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text("Start something in Kiku on your iPhone")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier("watch.nothingPlaying")
    }
}

/// The brief card after a mark, over the whole screen; `WatchSession` takes it away.
private struct MarkedCard: View {
    let confirmation: WatchSession.Confirmation

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bookmark.fill").font(.title).foregroundStyle(.tint)
            Text(confirmation.title).font(.headline)
            Text(confirmation.detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityIdentifier("watch.marked")
    }
}

/// The iPhone's volume on the crown (`WKInterfaceVolumeControl` with the companion as origin).
private struct PhoneVolume: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .companion)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.focus()
    }
}
