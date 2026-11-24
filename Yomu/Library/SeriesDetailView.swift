import AppCommon
import Core
import KavitaKit
import Names
import Readers
import SwiftUI

struct SeriesDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @State var series: KavitaSeries
    @State private var contents: KavitaSeriesContents?
    /// The volumes as Kavita has them (cached or just read); `contents` is these with this
    /// device's places applied by the one rule (`LocalReadingProgress.devicesPlaceWins`).
    @State private var kavitaContents: KavitaSeriesContents?
    /// This device's rows and the queue (nil until first read).
    @State private var places: DevicePlaces?
    @State private var error: String?
    @State private var session: ReaderSession?
    /// Each EPUB volume's characters, by chapter id (books only).
    @State private var lengths: [Int: BookLength] = [:]
    /// This device's reading of each volume (with the reader's character count, for books).
    @State private var localProgress: [Int: LocalReadingProgress] = [:]
    @State private var confirmsDownloadAll = false
    /// Which AniList series this is, for its character names.
    @State private var showsNamePicker = false
    @State private var needsNamePick = false

    /// Volumes and chapters not downloaded or downloading, with their row titles.
    private var notDownloadedWithTitles: [(KavitaChapter, String)] {
        guard let contents else { return [] }
        var result: [(KavitaChapter, String)] = []
        for volume in contents.volumes {
            for chapter in volume.chapters { result.append((chapter, chapter.displayTitle(in: volume))) }
        }
        result += (contents.looseChapters + contents.specials).map { ($0, $0.displayTitle(in: nil)) }
        return result.filter { environment.downloader.records[$0.0.id] == nil }
    }

    private var notDownloaded: [KavitaChapter] { notDownloadedWithTitles.map(\.0) }

    @State private var metadata: KavitaSeriesMetadata?
    @State private var tint: Color?
    @State private var layout = VolumeLayout.grid
    @State private var chaptersOf: KavitaVolume?
    /// The chapter picked in a volume's sheet, opened once the sheet has gone.
    @State private var pickedChapter: KavitaChapter?
    @State private var confirmsRemoveDownloads = false
    /// Mark Series as Read (true) or Unread (false), asked first.
    @State private var confirmsSeriesRead: Bool?
    /// In Kavita's Want to Read (the device's copy), and whether this server has it.
    @State private var wanted = false
    @State private var canWantToRead = false
    @State private var showsCollections = false
    /// The chapter whose Add to Reading List… is open.
    @State private var addingToList: KavitaChapter?

    /// Volumes as covers (default) or the rows with reading and download status.
    enum VolumeLayout: String, CaseIterable {
        case grid = "Grid", list = "List"
    }

    var body: some View {
        GeometryReader { geometry in
            if let columns = WideColumns.make(geometry) {
                // Wide (the iPhone Duo open, an iPad sideways): the cover and details on the
                // left, the volumes on the right.
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) { info }.padding()
                    }
                    .frame(width: columns.left)
                    .background(alignment: .top) {
                        TintedHeaderBackground(color: tint).frame(height: 420)
                    }
                    Color.clear.frame(width: columns.gap)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) { volumesAndReadAlong }.padding()
                    }
                    .frame(width: columns.right)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        info
                        volumesAndReadAlong
                    }
                    .padding()
                }
                .background(alignment: .top) {
                    TintedHeaderBackground(color: tint).frame(height: 420)
                }
            }
        }
        .navigationTitle(series.displayName)
        #if os(macOS)
        .pinnable(id: String(series.id), kind: series.isEpub ? "book" : "series", title: series.displayName)
        #endif
        .sheet(isPresented: $showsNamePicker) {
            CharacterNamePicker(series: environment.namedSeries(series))
        }
        .task(id: series.id) {
            // Whether the names dictionary is waiting for a pick (the reader asked and couldn't tell).
            let key = environment.namedSeries(series).key
            do {
                for try await match in environment.common.dictionaries.database.values({ try CharacterNameMatch.fetchOne($0, key: key) }) {
                    needsNamePick = match.map { $0.mediaKey == nil && $0.source != .picked } ?? false
                }
            } catch {}
        }
        .toolbar {
            if contents != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        if canWantToRead {
                            Button(wanted ? "Remove from Want to Read" : "Add to Want to Read", systemImage: wanted ? "star.slash" : "star") {
                                environment.setWantToRead(!wanted, seriesId: series.id)
                            }
                            .accessibilityIdentifier("series.wantToRead")
                        }
                        if environment.readerMarkAccount().map({ (try? environment.readerMarks.isAvailable(.collections, account: $0)) ?? true }) == true {
                            Button("Collections…", systemImage: "square.stack") { showsCollections = true }
                                .accessibilityIdentifier("series.collections")
                        }
                        if allChapters.contains(where: { !$0.isRead }) {
                            Button("Mark Series as Read…", systemImage: "checkmark.circle") { confirmsSeriesRead = true }
                                .accessibilityIdentifier("series.markRead")
                        }
                        if allChapters.contains(where: { $0.pagesRead > 0 }) {
                            Button("Mark Series as Unread…", systemImage: "circle") { confirmsSeriesRead = false }
                                .accessibilityIdentifier("series.markUnread")
                        }
                        Button("Character Names…", systemImage: "person.2") { showsNamePicker = true }
                            .accessibilityIdentifier("series.characterNames")
                        Button("Download \(notDownloaded.count) Volumes", systemImage: "arrow.down.circle") {
                            confirmsDownloadAll = true
                        }
                        .disabled(notDownloaded.isEmpty)
                        Button("Remove Downloads…", systemImage: "trash", role: .destructive) {
                            confirmsRemoveDownloads = true
                        }
                        .disabled(!allChapters.contains { environment.downloader.records[$0.id] != nil })
                    }
                    .accessibilityIdentifier("series.downloads")
                }
            }
        }
        // Every volume at once: asked first (undone by the opposite one).
        .confirmationDialog(confirmsSeriesRead == true ? "Mark every volume of \(series.displayName) as read?" : "Mark every volume of \(series.displayName) as unread?",
                            isPresented: Binding { confirmsSeriesRead != nil } set: { if !$0 { confirmsSeriesRead = nil } },
                            titleVisibility: .visible, presenting: confirmsSeriesRead) { read in
            Button(read ? "Mark as Read" : "Mark as Unread") { setRead(allChapters, read, wholeSeries: true) }
                .accessibilityIdentifier("series.markConfirm")
        } message: { read in
            Text(read ? "It isn't counted as reading time." : "Your place in each volume goes back to the start.")
        }
        // Every volume at once: asked first, as Settings ▸ Storage does.
        .confirmationDialog("Remove the downloads of \(series.displayName)?", isPresented: $confirmsRemoveDownloads, titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) {
                let records = allChapters.compactMap { environment.downloader.records[$0.id] }
                Task { for record in records { await environment.downloader.delete(record) } }
            }
        } message: {
            Text("Your place in each volume is kept. You can download them again.")
        }
        .confirmationDialog("Download \(notDownloaded.count) volumes of \(series.displayName)?",
                            isPresented: $confirmsDownloadAll, titleVisibility: .visible) {
            Button("Download") {
                for (chapter, title) in notDownloadedWithTitles {
                    environment.downloader.download(chapter, series: series, title: title)
                }
            }
        } message: {
            #if os(macOS)
            Text("They stay on this Mac until you remove them.")
            #else
            Text("They stay on this device until you remove them. Downloads wait for Wi-Fi unless cellular downloads are on in Settings.")
            #endif
        }
        .sheet(item: $chaptersOf, onDismiss: {
            // The reader can't come up over the sheet (iOS waited for Done; the Mac opened it behind).
            if let chapter = pickedChapter {
                pickedChapter = nil
                open(chapter)
            }
        }) { volume in
            NavigationStack {
                List(volume.chapters) { chapter in
                    chapterRow(chapter, title: chapter.displayTitle(in: volume))
                }
                .navigationTitle(volume.displayTitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { chaptersOf = nil } }
                }
            }
            .presentationDetents([.medium, .large])
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable {
            CoverLoader.recheck()
            await load()
        }
        .task {
            await load()
            await countCharacters()
        }
        .task { await loadMetadata() }
        .task(id: series.id) {
            // This device's rows and the queue: a page turn, a mark, or a change leaving the queue
            // (sent, or skipped for newer reading elsewhere) shows at once.
            do {
                for try await value in environment.readingProgress.observePlaces(seriesId: series.id) {
                    places = value
                    applyPlaces()
                }
            } catch {}
        }
        .sheet(isPresented: $showsCollections) { CollectionsSheet(seriesId: series.id) }
        .sheet(item: $addingToList) { chapter in ReadingListsSheet(chapter: readingListChapter(chapter)) }
        .task(id: environment.readerMarkAccount()) {
            guard let account = environment.readerMarkAccount() else { return }
            canWantToRead = (try? environment.readerMarks.isAvailable(.wantToRead, account: account)) ?? true
            Task { try? await environment.checkWantToRead(seriesId: series.id) }
            do {
                for try await ids in environment.wantToRead.observe(account: account) {
                    wanted = ids.contains(series.id)
                    canWantToRead = (try? environment.readerMarks.isAvailable(.wantToRead, account: account)) ?? true
                }
            } catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in Task { await load() } }
        .readerPresentation($session)
        .onReceive(NotificationCenter.default.publisher(for: .readerDidClose)) { _ in
            // Back from the reader: pick up the progress just made (after the outbox sends it).
            Task {
                try? await Task.sleep(for: .seconds(1))
                await load()
                await countCharacters()
            }
        }
    }

    /// The cover, title, actions, summary and genres.
    @ViewBuilder private var info: some View {
        header
        actions
        if let error {
            Label(error, systemImage: "wifi.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if needsNamePick {
            // Opening it couldn't tell which AniList series it is: asked once, remembered.
            Button("Pick the Series for Character Names", systemImage: "person.2") { showsNamePicker = true }
                .font(.callout)
                .accessibilityIdentifier("series.pickCharacterNames")
        }
        if let summary = metadata?.plainSummary {
            ExpandableText(summary)
        }
        if let genres = metadata?.genreNames, !genres.isEmpty {
            ChipRow(genres) { genre in
                Text(genre).font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.background.secondary, in: .capsule)
            }
        }
    }

    @ViewBuilder private var volumesAndReadAlong: some View {
        if let contents {
            volumes(contents)
            ReaderMarksSection(series: series, contents: contents) { chapter, mark in open(chapter, at: mark) }
            if series.isEpub, environment.serverAccounts[.audiobookshelf] != nil {
                ReadAlongSection(series: series, volumes: readAlongVolumes(contents))
            }
        } else if error == nil {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            CoverImage(request: environment.kavitaClient()?.seriesCoverRequest(seriesId: series.id)) { image in
                tint = CoverTint.color(of: image)
            }
            .frame(width: 130)
            .shadow(radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(series.displayName).font(.title2.bold())
                if series.displayName != series.name {
                    Text(series.name).font(.subheadline).foregroundStyle(.secondary)
                }
                if let writers = metadata?.writerNames, !writers.isEmpty {
                    Text(writers.joined(separator: ", ")).font(.subheadline)
                }
                Text(facts).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("series.facts")
            }
        }
    }

    /// "Manga · 4,708 pages", "Light novel · 4.9% read".
    private var facts: String {
        let library = (try? environment.kavitaLibrary.cachedLibraries())?.first { $0.id == series.libraryId }
        let kind: String
        switch library?.type {
        case KavitaLibraryType.lightNovel: kind = "Light novel"
        case KavitaLibraryType.book: kind = "Book"
        case KavitaLibraryType.comic, KavitaLibraryType.comicVine: kind = "Comic"
        default: kind = series.isEpub ? "Book" : "Manga"
        }
        if series.isEpub {
            return seriesCharacters.map { "\(kind) · \($0.percent) read" } ?? kind
        }
        return series.pages > 0 ? "\(kind) · \(series.pages.formatted()) pages" : kind
    }

    /// Continue (or start), and download the whole series.
    private var actions: some View {
        HStack(spacing: 12) {
            if let contents, let next = contents.continueChapter {
                Button {
                    open(next)
                } label: {
                    Label {
                        Text(continueTitle(contents)).lineLimit(1)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("series.continue")
            }
            if !notDownloaded.isEmpty {
                Button {
                    confirmsDownloadAll = true
                } label: {
                    Image(systemName: "arrow.down.circle").font(.title2)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("Download the series")
                .accessibilityIdentifier("series.downloadAll")
            }
        }
    }

    private func continueTitle(_ contents: KavitaSeriesContents) -> String {
        guard series.pagesRead > 0 else { return "Start Reading" }
        return ["Continue", contents.continueLabel(isEpub: series.isEpub, separator: ", ", characters: characterProgress)].compactMap(\.self).joined(separator: " · ")
    }

    // MARK: Volumes

    @ViewBuilder private func volumes(_ contents: KavitaSeriesContents) -> some View {
        if !contents.volumes.isEmpty {
            HStack {
                Text("Volumes").font(.title2.bold())
                Spacer()
                Picker("Layout", selection: $layout) {
                    ForEach(VolumeLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("series.layout")
            }
            switch layout {
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14)], spacing: 18) {
                    ForEach(contents.volumes) { volume in volumeTile(volume) }
                }
            case .list:
                group {
                    ForEach(contents.volumes) { volume in
                        if volume.chapters.count == 1, let chapter = volume.chapters.first {
                            chapterRow(chapter, title: chapter.displayTitle(in: volume))
                        } else {
                            DisclosureGroup(volume.displayTitle) {
                                ForEach(volume.chapters) { chapter in
                                    chapterRow(chapter, title: chapter.displayTitle(in: volume))
                                }
                            }
                        }
                    }
                }
            }
        }
        if !contents.looseChapters.isEmpty {
            Text("Chapters").font(.title2.bold())
            group { ForEach(contents.looseChapters) { chapterRow($0, title: $0.displayTitle(in: nil)) } }
        }
        if !contents.specials.isEmpty {
            Text("Specials").font(.title2.bold())
            group { ForEach(contents.specials) { chapterRow($0, title: $0.displayTitle(in: nil)) } }
        }
    }

    /// Rows in a rounded group, separated like a list.
    private func group(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(spacing: 0) {
            Divider().opacity(0)
            rows().padding(.vertical, 8)
        }
        .padding(.horizontal)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    /// A volume's cover with its download badge and progress strip; tapping opens it (or its chapters).
    private func volumeTile(_ volume: KavitaVolume) -> some View {
        let single = volume.chapters.count == 1 ? volume.chapters.first : nil
        let first = volume.chapters.first
        return Button {
            if let single { open(single) } else { chaptersOf = volume }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                CoverImage(request: first.flatMap { environment.kavitaClient()?.chapterCoverRequest(chapterId: $0.id) })
                    .overlay(alignment: .topTrailing) {
                        if let single { VolumeDownloadBadge(record: environment.downloader.records[single.id]).padding(6) }
                    }
                    .overlay(alignment: .bottom) {
                        // A book in characters, like the text below; manga in pages.
                        if series.isEpub {
                            if let read = single.flatMap(characterProgress), read.read > 0, read.read < read.total {
                                ProgressView(value: read.fraction)
                                    .tint(.accentColor)
                                    .padding(.horizontal, 6).padding(.bottom, 4)
                            }
                        } else if volume.pagesRead > 0, volume.pagesRead < volume.pages {
                            ProgressView(value: Double(volume.pagesRead), total: Double(max(volume.pages, 1)))
                                .tint(.accentColor)
                                .padding(.horizontal, 6).padding(.bottom, 4)
                        }
                    }
                    .opacity(volume.pages > 0 && volume.pagesRead >= volume.pages ? 0.6 : 1)
                Text(volume.chapters.count == 1 ? volume.displayTitle : "\(volume.displayTitle) · \(volume.chapters.count) chapters")
                    .font(.caption).lineLimit(1)
                Text(single.map(progressText) ?? "\(volume.pages) pages")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            readMenu(volume.chapters)
            if let single {
                let title = single.displayTitle(in: volume)
                if let record = environment.downloader.records[single.id] {
                    if record.state == .failed || record.state == .paused {
                        Button(record.state == .failed ? "Try Download Again" : "Resume Download", systemImage: "arrow.clockwise") {
                            environment.downloader.resume(record)
                        }
                    }
                    Button("Delete Download", systemImage: "trash", role: .destructive) {
                        Task { await environment.downloader.delete(record) }
                    }
                } else {
                    Button("Download", systemImage: "arrow.down.circle") {
                        environment.downloader.download(single, series: series, title: title)
                    }
                }
            }
        }
        .accessibilityIdentifier("volume.\(volume.name)")
    }

    /// The EPUB volumes (one book each) that can be paired with an audiobook.
    private func readAlongVolumes(_ contents: KavitaSeriesContents) -> [(chapter: KavitaChapter, title: String)] {
        contents.volumes.flatMap { volume in volume.chapters.map { (chapter: $0, title: $0.displayTitle(in: volume)) } }
            + (contents.looseChapters + contents.specials).map { (chapter: $0, title: $0.displayTitle(in: nil)) }
    }

    private func loadMetadata() async {
        guard let client = environment.kavitaClient() else { return }
        metadata = try? await client.seriesMetadata(seriesId: series.id)
    }

    /// Reading status on the left, download status on the right (both from Kavita and this device).
    private func chapterRow(_ chapter: KavitaChapter, title: String) -> some View {
        HStack(spacing: 8) {
            chapterButton(chapter, title: title)
            ChapterDownloadButton(chapter: chapter, series: series, title: title)
        }
        .contextMenu { readMenu([chapter]) }
    }

    /// A chapter as a reading list item.
    private func readingListChapter(_ chapter: KavitaChapter) -> ReadingListChapter {
        let volume = contents?.volumes.first { $0.chapters.contains { $0.id == chapter.id } }
        return ReadingListChapter(chapterId: chapter.id, seriesId: series.id, volumeId: chapter.volumeId, libraryId: series.libraryId,
                                  format: series.format, seriesName: series.displayName, title: chapter.displayTitle(in: volume))
    }

    /// Mark as Read / Mark as Unread for a volume's chapters (or one chapter): for something read
    /// in print or elsewhere, or to start one over.
    @ViewBuilder private func readMenu(_ chapters: [KavitaChapter]) -> some View {
        if chapters.count == 1, let chapter = chapters.first, environment.readerMarkAccount() != nil {
            Button("Add to Reading List…", systemImage: "text.badge.plus") { addingToList = chapter }
                .accessibilityIdentifier("chapter.addToReadingList")
        }
        if !chapters.isEmpty {
            if chapters.contains(where: { !$0.isRead }) {
                Button("Mark as Read", systemImage: "checkmark.circle") { setRead(chapters, true) }
            }
            if chapters.contains(where: { $0.pagesRead > 0 }) {
                Button("Mark as Unread", systemImage: "circle") { setRead(chapters, false) }
            }
        }
    }

    private func setRead(_ chapters: [KavitaChapter], _ read: Bool, wholeSeries: Bool = false) {
        environment.setRead(chapters, series: series, read, wholeSeries: wholeSeries)
        // On the page at once (Kavita follows through the outbox).
        contents = contents?.settingPagesRead(Dictionary(chapters.map { ($0.id, read ? $0.pages : 0) }, uniquingKeysWith: max))
        for chapter in chapters { localProgress[chapter.id] = try? environment.readingProgress.progress(chapterId: chapter.id) }
        if let contents {
            series.pagesRead = contents.readingOrder.reduce(0) { $0 + min($1.pagesRead, $1.pages) }
                + contents.specials.reduce(0) { $0 + min($1.pagesRead, $1.pages) }
        }
    }

    private func chapterButton(_ chapter: KavitaChapter, title: String) -> some View {
        Button {
            open(chapter)
        } label: {
            HStack(spacing: 12) {
                ReadingStatus(chapter: chapter, fraction: characterProgress(chapter)?.fraction)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(chapter.isRead ? .secondary : .primary)
                    Text(subtitle(chapter)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The progress line, plus the download's progress while it runs.
    private func subtitle(_ chapter: KavitaChapter) -> String {
        guard let record = environment.downloader.records[chapter.id], record.state == .downloading else { return progressText(chapter) }
        return "\(progressText(chapter)) · Downloading \(Int(((record.fraction ?? 0) * 100).rounded(.down)))%"
    }

    // MARK: Books: progress in characters

    /// Every volume of the series, in reading order.
    private var allChapters: [KavitaChapter] {
        (contents?.readingOrder ?? []) + (contents?.specials ?? [])
    }

    /// The whole series in characters as Yomu counts them (`BookCharacters`), never Kavita's
    /// percentage (its pages are a book's sections, which vary a lot).
    @ViewBuilder private var bookSeriesProgress: some View {
        if let read = seriesCharacters {
            ProgressView(value: read.fraction)
            Text("\(read.percent) read")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A percentage rounded down: one decimal under 10% ("0.5%"), so a started book never reads 0%.
    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let value = Double(min(part, whole)) / Double(whole) * 100
        return value < 10 ? "\(((value * 10).rounded(.down) / 10).formatted())%" : "\(Int(value.rounded(.down)))%"
    }

    /// A volume's characters read and in all (`BookCharacters`).
    private func characterProgress(_ chapter: KavitaChapter) -> BookProgress? {
        BookCharacters.progress(chapter, length: lengths[chapter.id], local: localProgress[chapter.id])
    }

    /// The whole series in characters.
    private var seriesCharacters: BookProgress? {
        BookCharacters.series(allChapters, lengths: lengths, local: localProgress)
    }

    /// The volumes' counts and this device's reading; volumes not counted yet are counted now
    /// from Kavita's text (or from the book, when it's on the device).
    private func countCharacters() async {
        guard series.isEpub else { return }
        for progress in (try? environment.readingProgress.progress(seriesId: series.id)) ?? [] {
            localProgress[progress.chapterId] = progress
        }
        lengths = (try? environment.bookLengths.lengths(seriesId: series.id)) ?? [:]
        let missing = allChapters.filter { lengths[$0.id]?.isStale(pages: $0.pages, wordCount: $0.wordCount) ?? true }
        guard !missing.isEmpty else { return }
        await environment.bookCounter.count(missing, seriesId: series.id)
        lengths = (try? environment.bookLengths.lengths(seriesId: series.id)) ?? [:]
    }

    /// A book's progress in characters (`BookCharacters`) with its size; manga in pages.
    private func progressText(_ chapter: KavitaChapter) -> String {
        if chapter.isRead { return "Finished" }
        if series.isEpub {
            if let read = characterProgress(chapter) {
                let size = "\(read.isEstimate ? "~" : "")\(read.total.formatted()) characters"
                return read.read > 0 || chapter.pagesRead > 0 ? "\(read.percent) · \(size)" : size
            }
            return chapter.pagesRead > 0 ? "Started" : "Not started"
        }
        if chapter.pagesRead > 0 {
            return "Page \(chapter.pagesRead + 1) of \(chapter.pages) · \(Self.percent(chapter.pagesRead, of: chapter.pages))"
        }
        return "\(chapter.pages) pages"
    }

    /// From a bookmark or highlight: opens at its page (and in a book, its place on the page).
    private func open(_ chapter: KavitaChapter, at mark: ReaderMark) {
        guard let contents else { return }
        session = ReaderSession(chapter: contents.readerChapter(chapter, series: series), series: series, contents: contents,
                                startPage: mark.page, startXPath: mark.xpath)
    }

    private func open(_ chapter: KavitaChapter) {
        guard let contents else { return }
        if chaptersOf != nil {
            pickedChapter = chapter
            chaptersOf = nil
            return
        }
        session = ReaderSession(chapter: contents.readerChapter(chapter, series: series), series: series, contents: contents)
    }

    /// Kavita's volumes with this device's places, by the one rule.
    private func applyPlaces() {
        guard let kavitaContents else { return }
        if places == nil { places = try? environment.readingProgress.places(seriesId: series.id) }
        let rows = places?.rows ?? []
        let applied = kavitaContents.readingFurther(Dictionary(rows.map { ($0.chapterId, $0.pagesRead) }, uniquingKeysWith: max),
                                                    updated: Dictionary(rows.map { ($0.chapterId, $0.updatedAt) }, uniquingKeysWith: max),
                                                    unsent: places?.unsentChapters(seriesId: series.id) ?? [])
        contents = applied
        // The header's total follows too.
        series.pagesRead = applied.readingOrder.reduce(0) { $0 + min($1.pagesRead, $1.pages) }
            + applied.specials.reduce(0) { $0 + min($1.pagesRead, $1.pages) }
    }

    private func load() async {
        let repository = environment.kavitaLibrary
        // What was read on this device counts too (manga read offline, or not sent yet), so the
        // rings, "Page x of y", Finished marks and Continue follow it at once.
        let saved = (try? environment.readingProgress.progress(seriesId: series.id)) ?? []
        let local = Dictionary(saved.map { ($0.chapterId, $0.pagesRead) }, uniquingKeysWith: max)
        if let cached = try? repository.cachedVolumes(seriesId: series.id), !cached.isEmpty {
            kavitaContents = KavitaSeriesContents(volumes: cached)
            applyPlaces()
        }
        guard let client = environment.kavitaClient() else { return }
        do {
            kavitaContents = KavitaSeriesContents(volumes: try await repository.refreshVolumes(seriesId: series.id, using: client))
            applyPlaces()
            if let refreshed = contents {
                let read = refreshed.readingOrder.reduce(0) { $0 + min($1.pagesRead, $1.pages) }
                    + refreshed.specials.reduce(0) { $0 + min($1.pagesRead, $1.pages) }
                series.pagesRead = read
                // Bookmarks and highlights made elsewhere (Kavita's own reader, another device).
                // Book bookmarks are listed per volume: only the volumes started (here or in Kavita).
                // And the volumes with a bookmark on this device (made, or kept from before).
                let saved = environment.readerMarkAccount().flatMap { try? environment.readerMarks.marks(account: $0, seriesId: series.id) }
                let marked = Set((saved ?? []).map(\.chapterId))
                let chapters = (refreshed.readingOrder + refreshed.specials)
                    .filter { $0.pagesRead > 0 || local[$0.id] != nil || marked.contains($0.id) }
                    .map { refreshed.readerChapter($0, series: series) }
                try? await environment.refreshMarks(seriesId: series.id, libraryId: series.libraryId, isBook: series.isEpub,
                                                    chapters: chapters.map { (chapterId: $0.chapterId, volumeId: $0.volumeId) })
            }
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = contents == nil ? error.localizedDescription : "Offline: showing saved chapters."
        }
    }
}

/// A volume cover's download state: a ring while it downloads, a grey arrow once it's here.
private struct VolumeDownloadBadge: View {
    let record: DownloadRecord?

    var body: some View {
        switch record?.state {
        case .downloading?:
            ProgressRing(fraction: record?.fraction ?? 0)
                .frame(width: 22, height: 22)
                .padding(3)
                .background(.ultraThinMaterial, in: .circle)
        case .done?:
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, .black.opacity(0.55))
        case .failed?:
            // Not the clock: a failed download isn't waiting for anything.
            Image(systemName: "exclamationmark.circle.fill").font(.title3).foregroundStyle(.white, .orange)
        case .queued?, .paused?:
            Image(systemName: "clock.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.55))
        case nil:
            EmptyView()
        }
    }
}

/// Not started (empty circle), in progress (a ring filling with Kavita's progress) or finished (check).
private struct ReadingStatus: View {
    let chapter: KavitaChapter
    /// A book's share read in characters, when its text is on the device.
    var fraction: Double?

    var body: some View {
        Group {
            if chapter.isRead {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint)
            } else if chapter.pagesRead > 0 || (fraction ?? 0) > 0 {
                ProgressRing(fraction: fraction ?? Double(chapter.pagesRead) / Double(max(chapter.pages, 1)))
                    .padding(2)
            } else {
                Circle().stroke(.tertiary, lineWidth: 2).padding(2)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityElement()
        .accessibilityLabel(chapter.isRead ? "Finished" : chapter.pagesRead > 0 ? "In progress" : "Not started")
    }
}

/// Download control for a volume or chapter row.
struct ChapterDownloadButton: View {
    @Environment(AppEnvironment.self) private var environment
    let chapter: KavitaChapter
    let series: KavitaSeries
    let title: String

    var body: some View {
        let downloader = environment.downloader
        let record = downloader.records[chapter.id]
        DownloadButton(record: record,
                       onDownload: {
                           if let record { downloader.resume(record) } else { downloader.download(chapter, series: series, title: title) }
                       },
                       onCancel: { if let record { Task { await downloader.delete(record) } } },
                       onDelete: { if let record { Task { await downloader.delete(record) } } })
    }
}
