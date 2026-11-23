import AppIntents
import KikuIntents
import SwiftUI
import WidgetKit

/// Kiku's widgets and controls (built only with `KIKU_WIDGETS=YES`: docs/kiku.md ▸ Widgets).
/// They show the snapshot Kiku writes to the App Group and run Kiku's intents, which play
/// inside the app; nothing here talks to a server.
@main
struct KikuWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        ResumeControl()
        MarkControl()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.inAppGroup()?.read() ?? .empty
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview && snapshot.current == nil ? .preview : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // Kiku reloads the widgets when what they show changes.
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: WidgetSnapshotStore.inAppGroup()?.read() ?? .empty)], policy: .never))
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        current: .init(key: "p", itemId: "", title: "第128回 季節のことば", show: "ことばの散歩ラジオ", timeLeft: 1260, fraction: 0.4),
        isPlaying: false, nextTitle: "Up Next",
        next: [.init(key: "q", itemId: "", title: "第129回 旅のはなし", show: "ことばの散歩ラジオ", timeLeft: 0, fraction: 0)],
        updatedAt: .now)
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KikuNowPlaying", provider: SnapshotProvider()) { entry in
            NowPlayingView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("What you're listening to in Kiku, with a play button.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private var current: WidgetSnapshot.Item? { snapshot.current }

    @ViewBuilder private var small: some View {
        if let current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Cover(itemId: current.itemId).frame(width: 52, height: 52)
                    Spacer()
                    PlayButton(isPlaying: snapshot.isPlaying)
                }
                Spacer(minLength: 0)
                Text(current.title).font(.caption.weight(.semibold)).lineLimit(2)
                Text(Self.left(current.timeLeft)).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            nothing
        }
    }

    @ViewBuilder private var medium: some View {
        if let current {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Cover(itemId: current.itemId).frame(width: 52, height: 52)
                        Spacer()
                        PlayButton(isPlaying: snapshot.isPlaying)
                    }
                    Spacer(minLength: 0)
                    Text(current.title).font(.caption.weight(.semibold)).lineLimit(2)
                    Text(Self.left(current.timeLeft)).font(.caption2).foregroundStyle(.secondary)
                }
                if !snapshot.next.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.nextTitle).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(snapshot.next) { item in
                            HStack(spacing: 6) {
                                Cover(itemId: item.itemId).frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.title).font(.caption2.weight(.medium)).lineLimit(2)
                                    Text(item.show).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            nothing
        }
    }

    @ViewBuilder private var circular: some View {
        if let current {
            Gauge(value: current.fraction) {
                Image(systemName: "headphones")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetURL(nil)
        } else {
            Image(systemName: "headphones")
        }
    }

    @ViewBuilder private var rectangular: some View {
        if let current {
            VStack(alignment: .leading, spacing: 1) {
                Text(current.title).font(.headline).lineLimit(1)
                Text(current.show).font(.caption).lineLimit(1)
                Text(Self.left(current.timeLeft)).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Kiku").font(.headline)
        }
    }

    private var nothing: some View {
        VStack(spacing: 6) {
            Image(systemName: "headphones").font(.title2).foregroundStyle(.secondary)
            Text("Nothing playing").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func left(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }
}

/// Plays without opening Kiku (the intent runs inside the app). While playing, it shows that.
struct PlayButton: View {
    let isPlaying: Bool

    var body: some View {
        Button(intent: ResumeIntent()) {
            Image(systemName: isPlaying ? "waveform" : "play.fill")
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.tint, in: .circle)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Playing" : "Resume")
    }
}

/// A show's or book's cover from the snapshot's folder.
struct Cover: View {
    let itemId: String

    var body: some View {
        Group {
            if let url = WidgetSnapshotStore.inAppGroup()?.coverURL(itemId: itemId),
               let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
    }
}

/// Control Center: Resume.
struct ResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "KikuResume") {
            ControlWidgetButton(action: ResumeIntent()) {
                Label("Resume", systemImage: "play.fill")
            }
        }
        .displayName("Resume in Kiku")
        .description("Plays what you were listening to.")
    }
}

/// Control Center: Mark what was just heard.
struct MarkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "KikuMark") {
            ControlWidgetButton(action: MarkIntent()) {
                Label("Mark", systemImage: "bookmark")
            }
        }
        .displayName("Mark in Kiku")
        .description("Marks the moment playing, to mine later.")
    }
}
