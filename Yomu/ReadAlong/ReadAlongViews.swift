import AppCommon
import AudiobookshelfKit
import Core
import Dictionary
import KavitaKit
import Readers
import SwiftUI

/// The reader's audio bar while reading along: sentence back, play/pause, sentence forward,
/// the time, speed, and Follow when paging by hand has stopped following. The controls come
/// and go with the reader's own; Follow Audio and From Here show either way.
struct ReadAlongBar: View {
    let model: ReadAlongModel
    /// The reader's controls are showing (a tap in the middle of the page toggles them).
    let showsControls: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let problem = model.problem {
                Text(problem).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                if model.tappedIndex != nil && !model.audio.isPlaying {
                    pill("From Here", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playFromTapped() }
                        .accessibilityIdentifier("readAlong.fromHere")
                } else if !model.follows {
                    pill("Follow Audio", systemImage: "location.fill") { model.follow() }
                        .accessibilityIdentifier("readAlong.follow")
                }
            }
            if showsControls { controls.transition(.opacity) }
        }
        .tint(Self.orange)
    }

    /// Read-along's colour (Kiku's orange).
    static let orange = Color(red: 0xF7 / 255, green: 0x9A / 255, blue: 0x3E / 255)

    private var controls: some View {
        HStack(spacing: 18) {
            Menu {
                ForEach(ListenSettings.speeds, id: \.self) { speed in
                    Button(speedText(speed)) { model.setSpeed(speed) }
                }
            } label: {
                Text(speedText(Double(model.audio.rate))).font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 40, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Speed")
            Button { model.previousSentence() } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44).contentShape(.rect) }
                .accessibilityLabel("Previous sentence")
                .accessibilityIdentifier("readAlong.previous")
            Button { model.toggle() } label: {
                Image(systemName: model.audio.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel(model.audio.isPlaying ? "Pause" : "Play")
            .accessibilityValue(model.audio.isPlaying ? "playing" : "paused")
            .accessibilityIdentifier("readAlong.playPause")
            .disabled(!model.isLoaded)
            Button { model.nextSentence() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44).contentShape(.rect) }
                .accessibilityLabel("Next sentence")
                .accessibilityIdentifier("readAlong.next")
            Text(Self.clock(model.audio.currentTime)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        // Taps between the buttons stay on the bar instead of reaching the page.
        .contentShape(.capsule)
        .onTapGesture {}
    }

    private func pill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// "1:07:43", or "7:43" under an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    private func speedText(_ speed: Double) -> String {
        speed == speed.rounded() ? String(format: "%.1f×", speed) : String(format: "%g×", speed)
    }
}

/// Above a lookup while reading along (like Kiku's): the looked-up sentence's clip, what the
/// card's audio will be.
struct ReadAlongClipRow: View {
    let model: ReadAlongModel

    var body: some View {
        if let cue = model.tappedCue {
            HStack(spacing: 12) {
                Button { model.playTappedClip() } label: {
                    Image(systemName: model.clip.isPlaying ? "stop.fill" : "play.fill")
                        .frame(width: 40, height: 40)
                        .background(.quaternary, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.clip.isPlaying ? "Stop the clip" : "Play the clip")
                .accessibilityIdentifier("lookup.playClip")
                Text("\(ReadAlongBar.clock(cue.start)) – \(ReadAlongBar.clock(cue.end)) · this clip goes on the card")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.background.secondary, in: .rect(cornerRadius: 18))
            .padding([.horizontal, .top])
            .tint(ReadAlongBar.orange)
        }
    }
}

/// The reader's headphones button: reading along on (orange) or off (plain reading).
struct ReadAlongSwitch: View {
    let model: ReadAlongModel

    var body: some View {
        Button("Read-Along", systemImage: "headphones") { model.setOn(!model.isOn) }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(model.isOn ? ReadAlongBar.orange : .secondary)
            .accessibilityValue(model.isOn ? "on" : "off")
            .accessibilityIdentifier("reader.readAlong")
    }
}

/// The series page's Read-Along section (EPUB series, once Audiobookshelf is set up): each
/// volume's pairing with an audiobook, getting it ready, and its audio download.
struct ReadAlongSection: View {
    @Environment(AppEnvironment.self) private var environment
    let series: KavitaSeries
    let volumes: [(chapter: KavitaChapter, title: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read-Along").font(.title2.bold())
            VStack(spacing: 0) {
                ForEach(Array(volumes.enumerated()), id: \.element.chapter.id) { index, volume in
                    if index > 0 { Divider() }
                    ReadAlongRow(series: series, chapter: volume.chapter, title: volume.title)
                }
            }
            .padding(.horizontal)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            Text("Plays a matching audiobook with the text: the spoken sentence lights up and pages turn with it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readAlong.section")
    }
}

private struct ReadAlongRow: View {
    @Environment(AppEnvironment.self) private var environment
    let series: KavitaSeries
    let chapter: KavitaChapter
    let title: String
    @State private var pair: ReadAlongPair?
    @State private var choosing = false
    @State private var preparing: Double?
    @State private var message: String?
    @State private var download: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: pair?.cues != nil ? "headphones.circle.fill" : "headphones.circle")
                    .font(.title2).foregroundStyle(pair?.cues != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if let preparing {
                    ProgressView(value: preparing).frame(width: 60)
                } else {
                    menu
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 10)
        .task { await observe() }
        .sheet(isPresented: $choosing) {
            PairingSheet(series: series, chapter: chapter) { book in
                choosing = false
                Task { await pairAndPrepare(book) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readAlong.row")
    }

    private var status: String {
        guard let pair else { return "Not paired" }
        if let matched = pair.matchedSentences, let total = pair.totalSentences, pair.cues != nil {
            let share = total > 0 ? Int((Double(matched) / Double(total) * 100).rounded()) : 0
            let audio = ReadAlongAudio.localFile(itemId: pair.itemId) != nil ? " · audio downloaded" : ""
            return "\(pair.bookTitle) · \(share)% of sentences matched\(audio)"
        }
        return "\(pair.bookTitle) · not ready yet"
    }

    @ViewBuilder private var menu: some View {
        Menu {
            if let pair {
                if pair.cues == nil {
                    Button("Get Ready", systemImage: "waveform.badge.magnifyingglass") { Task { await prepare(pair) } }
                } else {
                    Button("Match Again", systemImage: "arrow.clockwise") { Task { await prepare(pair, again: true) } }
                }
                if let file = ReadAlongAudio.localFile(itemId: pair.itemId) {
                    Button("Delete Audio Download", systemImage: "trash", role: .destructive) {
                        try? FileManager.default.removeItem(at: file)
                        message = nil
                        self.pair = pair
                    }
                } else if download == nil {
                    Button("Download Audio", systemImage: "arrow.down.circle") { Task { await downloadAudio(pair) } }
                }
                Button("Pair with Another Book…", systemImage: "link") { choosing = true }
                Button("Unpair", systemImage: "link.badge.plus", role: .destructive) {
                    try? environment.readAlongPairs.unpair(chapterId: chapter.id)
                }
            } else {
                Button("Pair with an Audiobook…", systemImage: "link") { choosing = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .accessibilityIdentifier("readAlong.menu")
    }

    private func observe() async {
        do {
            for try await value in environment.readAlongPairs.observe(chapterId: chapter.id) { pair = value }
        } catch {}
    }

    private func pairAndPrepare(_ book: AudiobookshelfItem) async {
        let new = ReadAlongPair(chapterId: chapter.id, itemId: book.id, bookTitle: book.title, createdAt: .now)
        try? environment.readAlongPairs.pair(new)
        await prepare(new)
    }

    /// Reads the book's text, fetches Kaku's transcript and matches them (asking Kaku for the
    /// transcript first when it has none).
    private func prepare(_ pair: ReadAlongPair, again: Bool = false) async {
        guard let kaku = environment.kakuClient() else {
            message = "Set up Kaku in Settings: it has the audiobook's transcript."
            return
        }
        preparing = 0
        defer { preparing = nil }
        message = nil
        do {
            let document: KakuTranscript
            switch try await kaku.transcript(itemId: pair.itemId, episodeId: "") {
            case .ready(let ready): document = ready
            case .pending(let job):
                message = "Kaku is transcribing the audiobook\(job.progress.map { " (\(Int($0 * 100))%)" } ?? ""). Get it ready again when it's done."
                return
            case .missing:
                try await kaku.requestJob(itemId: pair.itemId, episodeId: "")
                message = "Kaku has started transcribing the audiobook (about 4 minutes an hour of audio). Get it ready again when it's done."
                return
            }
            preparing = 0.1
            let runs = try await BookTextCollector.runs(chapterId: chapter.id, repository: environment.books) { fraction in
                preparing = 0.1 + fraction * 0.7
            }
            let words = document.sentences.flatMap { sentence in
                sentence.words.isEmpty ? [TimedWord(text: sentence.text, start: sentence.start, end: sentence.end)]
                    : sentence.words.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) }
            }
            let cues = await Task.detached { ReadAlongAligner.align(runs: runs, words: words) }.value
            let total = runs.reduce(0) { $0 + TextScanner.sentences(in: $1.text).count }
            try environment.readAlongPairs.saveAlignment(
                chapterId: chapter.id, cues: ReadAlongCues(cues).data, version: ReadAlongCues.version,
                fingerprint: document.source.fingerprint, matched: cues.count, total: total, at: .now)
            if cues.isEmpty { message = "The book and the audiobook didn't match. Is it the same edition?" }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Yomu's own copy of the audiobook (Application Support/ReadAlongAudio), for offline reading along.
    private func downloadAudio(_ pair: ReadAlongPair) async {
        guard let client = environment.audiobookshelfClient(), let item = try? await client.item(id: pair.itemId),
              let whole = AudiobookshelfEpisode.wholeBook(item), let file = whole.audioFile,
              let request = try? await client.audioRequest(itemId: pair.itemId, ino: file.ino) else {
            message = "Sign in to Audiobookshelf in Settings to download the audio."
            return
        }
        download = 0
        defer { download = nil }
        message = "Downloading the audio… Keep Yomu open."
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: ReadAlongAudio.folder, withIntermediateDirectories: true)
            var folder = ReadAlongAudio.folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            let destination = ReadAlongAudio.folder.appending(path: "\(pair.itemId).\(file.fileExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            message = "Audio downloaded (\(bytes.storageText))."
        } catch {
            message = "Couldn't download the audio: \(error.localizedDescription)"
        }
    }
}

/// Choosing the audiobook for a volume: likely matches first (title and author), then every
/// book in Audiobookshelf.
private struct PairingSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let series: KavitaSeries
    let chapter: KavitaChapter
    let choose: (AudiobookshelfItem) -> Void
    /// Each book library's audiobooks, in Audiobookshelf's order.
    @State private var libraries: [(name: String, books: [AudiobookshelfItem])]?
    @State private var problem: String?
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if let problem { Text(problem).foregroundStyle(.secondary) }
                if let libraries {
                    let suggested = libraries.flatMap(\.books).filter { Self.matches($0, series: series) }
                    if !suggested.isEmpty && search.isEmpty {
                        Section("Suggested") { ForEach(suggested) { row($0) } }
                    }
                    // A section per library, so a library in another language is easy to skip.
                    ForEach(libraries, id: \.name) { library in
                        let books = library.books.filter { Self.matches($0, search: search) }
                        if !books.isEmpty { Section(library.name) { ForEach(books) { row($0) } } }
                    }
                } else if problem == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .searchable(text: $search, prompt: "Title or Author")
            .navigationTitle("Pair with an Audiobook")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
    }

    private func row(_ book: AudiobookshelfItem) -> some View {
        Button { choose(book) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).foregroundStyle(.primary)
                if let author = book.media.metadata.authorName, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("pairing.book")
    }

    private func load() async {
        guard let client = environment.audiobookshelfClient() else {
            problem = "Sign in to Audiobookshelf in Settings first."
            return
        }
        do {
            var found: [(name: String, books: [AudiobookshelfItem])] = []
            for library in try await client.libraries() where library.mediaType == .book {
                let books = try await client.items(libraryId: library.id)
                found.append((library.name, books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }))
            }
            libraries = found
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The search text in the title or author, ignoring case and width.
    static func matches(_ book: AudiobookshelfItem, search: String) -> Bool {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return [book.title, book.media.metadata.authorName ?? ""].contains {
            $0.range(of: text, options: [.caseInsensitive, .widthInsensitive]) != nil
        }
    }

    /// The same title once 小説 and spaces are set aside, either way round.
    static func matches(_ book: AudiobookshelfItem, series: KavitaSeries) -> Bool {
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "小説", with: "").components(separatedBy: .whitespacesAndNewlines).joined()
                .precomposedStringWithCompatibilityMapping.lowercased()
        }
        let a = plain(book.title), b = plain(series.name)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }
}
