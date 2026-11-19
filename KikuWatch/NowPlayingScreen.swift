import KikuWatchLink
import SwiftUI
import WatchKit

/// The first screen: what's playing (on the iPhone, or in Watch mode on this watch), its
/// controls and a large Mark button; or a calm note when nothing is. The crown turns the
/// volume of whichever plays. With Live Text on, the top-left button opens the transcript; the
/// top-right one shows the mode (a phone or a watch) and opens Play On and On This Watch.
struct NowPlayingScreen: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        ZStack {
            if let playing = session.nowPlaying {
                NowPlayingControls(playing: playing)
            } else if session.mode == .watch {
                NothingPlaying(text: "Choose something on this watch: tap the watch button above.")
            } else {
                NothingPlaying(text: "Start something in Kiku on your iPhone")
            }
            if let confirmation = session.confirmation {
                ConfirmationCard(confirmation: confirmation)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.confirmation)
        .toolbar {
            if session.liveTextOn, session.nowPlaying != nil {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        LiveTextScreen()
                    } label: {
                        // White on the tinted button (the default glyph took the tint, and vanished).
                        Image(systemName: "text.quote").foregroundStyle(.white)
                    }
                    .accessibilityLabel("Live Text")
                    .accessibilityIdentifier("watch.liveText")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    OnThisWatchScreen()
                } label: {
                    Image(systemName: session.mode == .watch ? "applewatch" : "iphone").foregroundStyle(.white)
                }
                .accessibilityLabel(session.mode == .watch ? "Playing on this watch" : "Playing on iPhone")
                .accessibilityIdentifier("watch.onThisWatch")
            }
        }
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
            // Takes the crown: it turns the volume of whichever plays, as in Apple's Now Playing.
            Volume(origin: session.mode == .watch ? .local : .companion)
                .id(session.mode)
                .scaleEffect(0.55).frame(width: 26, height: 26)
        }
        // Clear of the Live Text button in the top corner.
        .padding(.top, session.liveTextOn ? 10 : 0)
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

    /// Each button takes a third of the width and 40 pt of height, so they're easy to hit.
    private var controls: some View {
        HStack(spacing: 0) {
            Button { session.send(.skipBackward) } label: {
                controlImage(Self.skipSymbol("gobackward", playing.skipBackward), size: 24)
            }
            .accessibilityLabel("Back \(Int(playing.skipBackward)) seconds")
            Button { session.send(.togglePlay) } label: {
                controlImage(playing.isPlaying ? "pause.fill" : "play.fill", size: 30)
            }
            .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("watch.playPause")
            Button { session.send(.skipForward) } label: {
                controlImage(Self.skipSymbol("goforward", playing.skipForward), size: 24)
            }
            .accessibilityLabel("Forward \(Int(playing.skipForward)) seconds")
        }
        .buttonStyle(.plain)
    }

    private func controlImage(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(.rect)
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
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image("KikuGlyph")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier("watch.nothingPlaying")
    }
}

/// The brief card after a mark or a card added, over the whole screen; `WatchSession` takes it away.
struct ConfirmationCard: View {
    let confirmation: WatchSession.Confirmation

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: confirmation.symbol).font(.title).foregroundStyle(.tint)
            Text(confirmation.title).font(.headline)
            Text(confirmation.detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityIdentifier("watch.marked")
    }
}

/// The volume on the crown (`WKInterfaceVolumeControl`): the iPhone's (`.companion`), or this
/// watch's own in Watch mode (`.local`).
private struct Volume: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: origin)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.focus()
    }
}
