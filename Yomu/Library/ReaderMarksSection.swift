import Core
import KavitaKit
import SwiftUI

/// A series' bookmarks and highlights, as Kavita keeps them (and this device's unsent ones):
/// pick one to read from there, hold one to remove it.
struct ReaderMarksSection: View {
    @Environment(AppEnvironment.self) private var environment
    let series: KavitaSeries
    let contents: KavitaSeriesContents
    let open: (KavitaChapter, _ page: Int) -> Void
    @State private var marks: [ReaderMark] = []
    @State private var annotationsAvailable = true

    var body: some View {
        // A stack rather than a Group: with no marks yet a Group is nothing, and its task never ran.
        VStack(alignment: .leading, spacing: 18) {
            if !marks.isEmpty || !annotationsAvailable {
                Text("Bookmarks & Highlights").font(.title2.bold())
                    .accessibilityIdentifier("series.marks")
                if !annotationsAvailable {
                    Text("This Kavita server is too old for highlights and notes (they need Kavita 0.8.8 or later).")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("series.marks.tooOld")
                }
                VStack(spacing: 0) {
                    ForEach(marks) { mark in
                        row(mark)
                        if mark.id != marks.last?.id { Divider() }
                    }
                }
                .padding(.horizontal)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
        }
        .task(id: environment.readerMarkAccount()) {
            guard let account = environment.readerMarkAccount() else { return }
            annotationsAvailable = !series.isEpub || ((try? environment.readerMarks.isAvailable(.annotations, account: account)) ?? true)
            do {
                for try await marks in environment.readerMarks.observe(account: account, seriesId: series.id) {
                    self.marks = marks
                    annotationsAvailable = !series.isEpub || ((try? environment.readerMarks.isAvailable(.annotations, account: account)) ?? true)
                }
            } catch {}
        }
    }

    private func row(_ mark: ReaderMark) -> some View {
        let chapter = place(of: mark)
        return Button {
            if let chapter = chapter?.chapter { open(chapter, mark.page) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                icon(mark)
                VStack(alignment: .leading, spacing: 3) {
                    switch mark.kind {
                    case .pageBookmark:
                        Text("Page \(mark.page + 1)")
                    case .bookBookmark:
                        Text(mark.title ?? "Page \(mark.page + 1)").lineLimit(2)
                    case .highlight:
                        Text(mark.text ?? "").lineLimit(3)
                        if let note = mark.note {
                            Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Text([chapter?.title, mark.state == .synced ? nil : "Not on Kavita yet"].compactMap(\.self).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(mark.kind == .highlight ? "Remove Highlight" : "Remove Bookmark", systemImage: "trash", role: .destructive) {
                guard let id = mark.id else { return }
                try? environment.readerMarks.remove(id, outbox: environment.outbox)
                environment.syncNow()
            }
        }
        .accessibilityIdentifier("series.mark")
    }

    @ViewBuilder private func icon(_ mark: ReaderMark) -> some View {
        switch mark.kind {
        case .pageBookmark, .bookBookmark:
            Image(systemName: "bookmark.fill").foregroundStyle(.tint)
        case .highlight:
            Circle().fill(Self.slotColor(mark.slot)).frame(width: 12, height: 12)
        }
    }

    /// Kavita's default highlight colours (cyan, green, yellow, orange, magenta).
    static func slotColor(_ slot: Int) -> Color {
        [Color.cyan, .green, .yellow, .orange, .pink][min(max(slot, 0), 4)]
    }

    /// The mark's volume or chapter, and its name.
    private func place(of mark: ReaderMark) -> (chapter: KavitaChapter, title: String)? {
        for volume in contents.volumes {
            if let chapter = volume.chapters.first(where: { $0.id == mark.chapterId }) { return (chapter, chapter.displayTitle(in: volume)) }
        }
        return (contents.looseChapters + contents.specials).first { $0.id == mark.chapterId }.map { ($0, $0.displayTitle(in: nil)) }
    }
}
