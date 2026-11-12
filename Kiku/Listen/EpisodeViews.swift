import AppCommon
import AudiobookshelfKit
import SwiftUI

/// Kaku's transcript state beside an episode: "字 Transcript" when it's ready, "Transcribing"
/// while queued or running, nothing for libraries Kaku doesn't cover.
struct TranscriptBadge: View {
    let status: KakuStatus?

    var body: some View {
        switch status {
        case .done?:
            Label { Text("Transcript") } icon: { Text("字") }
                .labelStyle(BadgeLabelStyle())
                .foregroundStyle(.tint)
                .background(.tint.opacity(0.18), in: .capsule)
                .accessibilityIdentifier("badge.transcript")
        case .queued?, .running?:
            Label { Text("Transcribing") } icon: { ProgressView().controlSize(.mini) }
                .labelStyle(BadgeLabelStyle())
                .foregroundStyle(.secondary)
                .background(.quaternary, in: .capsule)
                .accessibilityIdentifier("badge.transcribing")
        default:
            EmptyView()
        }
    }

    private struct BadgeLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
    }
}

/// Played state on the left of an episode row: empty circle, a ring when partly played, a
/// filled check when played.
struct PlayedStateIcon: View {
    let entry: EpisodeEntry

    var body: some View {
        Group {
            if entry.isFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            } else if entry.isStarted {
                ProgressRing(fraction: max(entry.fraction, 0.08)).frame(width: 22, height: 22)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
        .font(.title2)
        .frame(width: 28)
        .accessibilityLabel(entry.isFinished ? "Played" : entry.isStarted ? "In progress" : "Unplayed")
    }
}

extension EpisodeEntry {
    /// "Today · 48 min", or the time left once started.
    var dateAndLength: String {
        var parts: [String] = []
        if let date = episode.publishedDate { parts.append(Self.dayText(date)) }
        if isStarted && !isFinished {
            parts.append("\(timeLeft.lengthText) left")
        } else if duration > 0 {
            parts.append(duration.lengthText)
        }
        return parts.joined(separator: " · ")
    }

    static func dayText(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}

/// A row in New Episodes (K1): artwork, title, show · date · length, badge, play.
struct NewEpisodeRow: View {
    @Environment(KikuEnvironment.self) private var environment
    let entry: EpisodeEntry

    var body: some View {
        HStack(spacing: 12) {
            ShowCover(itemId: entry.itemId).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.episode.title).lineLimit(1)
                // The date first: a long show title would cut it off.
                Text([entry.dateAndLength, entry.showTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                TranscriptBadge(status: environment.library.transcriptStatus[entry.id])
            }
            Spacer(minLength: 8)
            Button { environment.play(entry) } label: {
                Image(systemName: "play.fill")
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(entry.episode.title)")
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityIdentifier("listen.episode")
    }
}

/// A row on a show page (K3): played state, title, date · length with the badge, download.
struct ShowEpisodeRow: View {
    @Environment(KikuEnvironment.self) private var environment
    let entry: EpisodeEntry

    var body: some View {
        HStack(spacing: 12) {
            PlayedStateIcon(entry: entry)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.episode.title).lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.dateAndLength).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    TranscriptBadge(status: environment.library.transcriptStatus[entry.id])
                }
            }
            Spacer(minLength: 8)
            EpisodeDownloadButton(entry: entry)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
        .onTapGesture { environment.play(entry) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { environment.play(entry) }
        .accessibilityIdentifier("show.episode")
    }
}

/// Download control for an episode row (the same icons as Yomu and Miru).
struct EpisodeDownloadButton: View {
    @Environment(KikuEnvironment.self) private var environment
    let entry: EpisodeEntry

    var body: some View {
        let downloader = environment.downloader!
        let record = downloader.records[entry.id]
        DownloadButton(record: record,
                       onDownload: {
                           Task { record == nil ? await downloader.download(entry) : await downloader.resume(record!) }
                       },
                       onCancel: { if let record { Task { await downloader.delete(record) } } },
                       onDelete: { if let record { Task { await downloader.delete(record) } } })
            .font(.title2)
            .accessibilityIdentifier("episode.download")
    }
}

/// Removes tags from a podcast's HTML description.
enum PlainText {
    static func from(html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
