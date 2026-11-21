import KikuWatchLink
import SwiftUI
import WidgetKit

/// Kiku's complication and Smart Stack widget: the bird glyph, with the playing item's progress
/// (corner gauge, circular ring) or its title and chapter (rectangular). Tapping opens the watch
/// app's Now Playing. The watch app saves what Now Playing shows (`WatchStateStore.saveShown`: the
/// phone's, or this watch's own in Watch mode) and reloads this timeline on real changes only.
@main
struct KikuWidgets: WidgetBundle {
    var body: some Widget {
        KikuComplication()
    }
}

struct KikuComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KikuNowPlaying", provider: NowPlayingProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Kiku")
        .description("What's playing in Kiku, on your iPhone or this watch.")
        .supportedFamilies([.accessoryCorner, .accessoryCircular, .accessoryRectangular])
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let playing: WatchNowPlaying?
}

struct NowPlayingProvider: TimelineProvider {
    /// While playing, a few entries ahead so the gauge moves, not one a second.
    static let steps = 4
    static let step: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, playing: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, playing: WatchStateStore.loadShown()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Self.timeline(for: WatchStateStore.loadShown(), now: .now))
    }

    static func timeline(for playing: WatchNowPlaying?, now: Date) -> Timeline<NowPlayingEntry> {
        guard let playing, playing.isPlaying else {
            return Timeline(entries: [NowPlayingEntry(date: now, playing: playing)], policy: .never)
        }
        let entries = (0..<steps).map { NowPlayingEntry(date: now.addingTimeInterval(Double($0) * step), playing: playing) }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    private var fraction: Double? { entry.playing.map { $0.fraction(at: entry.date) } }

    var body: some View {
        switch family {
        case .accessoryCorner:
            glyph
                .padding(2)
                .widgetLabel {
                    if let fraction { ProgressView(value: fraction).tint(.orange) }
                }
        case .accessoryCircular:
            if let fraction {
                Gauge(value: fraction) {} currentValueLabel: { glyph.padding(9) }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(.orange)
            } else {
                glyph.padding(6)
            }
        default:
            rectangular
        }
    }

    private var glyph: some View {
        Image("KikuGlyph")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .widgetAccentable()
            .accessibilityLabel("Kiku")
    }

    /// The Smart Stack: "KIKU", the title, and the chapter (or show). No Mark button: a widget's
    /// button runs in this extension, which can't reach the phone, so a tap opens the app instead.
    private var rectangular: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("KIKU").font(.caption2.weight(.bold)).foregroundStyle(.orange).widgetAccentable()
                if let playing = entry.playing {
                    Text(playing.title).font(.headline).lineLimit(1)
                    Text(playing.chapter ?? playing.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let fraction { ProgressView(value: fraction).tint(.orange) }
                } else {
                    Text("Nothing playing").font(.headline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            glyph.frame(width: 22, height: 22)
        }
    }
}
