import AppCommon
import AudiobookshelfKit
import SwiftUI

/// A book's page, built like a show page (K3): tinted header, author · narrator, Resume or
/// Play, the description, the download, and the chapters (tap one to play from there).
struct BookView: View {
    @Environment(KikuEnvironment.self) private var environment
    let itemId: String
    @State private var tint: Color?
    @State private var loaded = false

    private var book: AudiobookshelfItem? { environment.library.book(itemId) }
    /// Needs the book's details (its tracks) to play.
    private var entry: EpisodeEntry? { environment.library.bookDetails[itemId].flatMap { environment.library.entry(book: $0) } }
    /// Where you are: the player's time while it's this book, else the saved progress.
    private var position: Double {
        if let playback = environment.playback, playback.key == itemId { return playback.audio.currentTime }
        return environment.library.progress[itemId]?.currentTime ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 16) {
                    ShowCover(itemId: itemId, cornerRadius: 16) { image in tint = CoverTint.color(of: image) }
                        .frame(width: 130, height: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book?.title ?? "").font(.title.bold()).lineLimit(3)
                        if let people = people { Text(people).foregroundStyle(.secondary).lineLimit(2) }
                        Text(lengthLine).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let entry {
                    if entry.fileCount > 1 {
                        Label("This book has \(entry.fileCount) files. Kiku plays single-file books for now.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) {
                            Button { environment.play(entry) } label: {
                                Label(entry.isStarted && !entry.isFinished ? "Resume" : "Play", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .foregroundStyle(Color(red: 0x3A / 255, green: 0x1A / 255, blue: 0x05 / 255))
                            .accessibilityIdentifier("book.play")
                            EpisodeDownloadButton(entry: entry)
                        }
                        HStack(spacing: 8) {
                            TranscriptBadge(status: environment.library.transcriptStatus[itemId])
                            Spacer()
                            ReadInYomuButton(entry: entry)
                                .font(.subheadline)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                    }
                }
                if let description = book?.media.metadata.description, !description.isEmpty {
                    ExpandableText(PlainText.from(html: description))
                }
                if let entry, !entry.chapters.isEmpty {
                    Text("Chapters").font(.title2.bold())
                    VStack(spacing: 0) {
                        let current = entry.chapter(at: position)?.id
                        ForEach(Array(entry.chapters.enumerated()), id: \.element.id) { index, chapter in
                            if index > 0 { Divider().padding(.leading, 40) }
                            ChapterRow(chapter: chapter, isCurrent: chapter.id == current && position > 0) {
                                if entry.fileCount == 1 { environment.play(entry, at: chapter.start) }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .background(.background.secondary, in: .rect(cornerRadius: 20))
                }
            }
            .padding()
        }
        .background(alignment: .top) {
            TintedHeaderBackground(color: tint).frame(height: 420)
        }
        .overlay {
            if entry == nil && !loaded { ProgressView() }
        }
        .navigationTitle(book?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: itemId) {
            await environment.library.loadBook(itemId)
            loaded = true
        }
        .refreshable { await environment.library.loadBook(itemId) }
    }

    /// "著者 · Read by 朗読者".
    private var people: String? {
        let metadata = book?.media.metadata
        let parts = [metadata?.authorName, metadata?.narratorName.map { "Read by \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty && $0 != "Read by " }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Audiobook · 6 h 34 min", or the time left once started.
    private var lengthLine: String {
        let duration = book?.media.duration ?? 0
        let progress = environment.library.progress[itemId]
        if let progress, progress.isFinished { return "Audiobook · Finished" }
        if let progress, progress.currentTime > 0, duration > 0 {
            return "Audiobook · \(max(duration - progress.currentTime, 0).lengthText) left"
        }
        return duration > 0 ? "Audiobook · \(duration.lengthText)" : "Audiobook"
    }
}

/// One chapter: its title and length, with the current one marked.
private struct ChapterRow: View {
    let chapter: AudiobookshelfChapter
    let isCurrent: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.circle")
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title).lineLimit(2).foregroundStyle(.primary).fontWeight(isCurrent ? .semibold : .regular)
                    Text("\(chapter.start.clockText) · \((chapter.end - chapter.start).lengthText)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isCurrent ? "book.currentChapter" : "book.chapter")
    }
}
