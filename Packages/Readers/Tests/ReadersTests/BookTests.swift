import Core
import Foundation
import KavitaKit
@testable import Readers
import Synchronization
import Testing
import ZIPFoundation

/// Builds small EPUBs for tests.
enum TestEpub {
    static let container = """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """

    static let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <metadata><dc:title>そら ソラ 空 ガーデン</dc:title><dc:language>ja</dc:language><meta name="cover" content="cover-img"/></metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="cover-img" href="images/cover.jpg" media-type="image/jpeg"/>
          <item id="p1" href="text/p%201.xhtml" media-type="application/xhtml+xml"/>
          <item id="p2" href="text/p2.xhtml" media-type="application/xhtml+xml"/>
          <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine toc="ncx" page-progression-direction="rtl">
          <itemref idref="p1"/><itemref idref="notes" linear="no"/><itemref idref="p2"/>
        </spine></package>
        """

    static let nav = """
        <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body><nav epub:type="toc"><ol>
          <li><a href="text/p%201.xhtml">１ 空の庭</a><ol><li><a href="text/p2.xhtml#s2">２ 少女</a></li></ol></li>
        </ol></nav></body></html>
        """

    static let ncx = """
        <?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
        <navPoint id="a"><navLabel><text>NCX one</text></navLabel><content src="text/p%201.xhtml"/>
          <navPoint id="b"><navLabel><text>NCX two</text></navLabel><content src="text/p2.xhtml#s2"/></navPoint></navPoint>
        </navMap></ncx>
        """

    static func page(_ text: String) -> String {
        #"<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><body><p>\#(text)</p></body></html>"#
    }

    static func files(nav: Bool = true) -> [String: Data] {
        var files: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data(container.utf8),
            "OEBPS/content.opf": Data((nav ? opf : opf.replacingOccurrences(of: #" properties="nav""#, with: "")).utf8),
            "OEBPS/toc.ncx": Data(ncx.utf8),
            "OEBPS/images/cover.jpg": Data([0xFF, 0xD8, 0xFF, 0xD9]),
            "OEBPS/text/p 1.xhtml": Data(page("吾輩は猫である。").utf8),
            "OEBPS/text/p2.xhtml": Data(page("名前はまだ無い。").utf8),
            "OEBPS/text/notes.xhtml": Data(page("注").utf8),
        ]
        if nav { files["OEBPS/nav.xhtml"] = Data(Self.nav.utf8) }
        return files
    }

    static func zip(_ files: [String: Data]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return try #require(archive.data)
    }
}

@Suite struct EpubPackageTests {
    func unpacked(nav: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "epub-\(UUID().uuidString)")
        try BookRepository.unpack(try TestEpub.zip(TestEpub.files(nav: nav)), into: folder)
        return folder
    }

    @Test func readsSpineDirectionCoverAndNavTOC() throws {
        let folder = try unpacked()
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = try EpubPackage.parse(folder: folder)
        #expect(book.title == "そら ソラ 空 ガーデン" && book.language == "ja")
        #expect(book.spine.map(\.path) == ["OEBPS/text/p 1.xhtml", "OEBPS/text/notes.xhtml", "OEBPS/text/p2.xhtml"])
        #expect(book.spine.map(\.linear) == [true, false, true], "Kavita counts every spine item, linear or not")
        #expect(book.pageProgressionRTL)
        #expect(book.coverPath == "OEBPS/images/cover.jpg")
        #expect(book.toc.map(\.title) == ["１ 空の庭", "２ 少女"])
        #expect(book.toc.map(\.spineIndex) == [0, 2])
        #expect(book.toc[1].fragment == "s2" && book.toc[1].depth == 1)
    }

    @Test func fallsBackToNCX() throws {
        let folder = try unpacked(nav: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = try EpubPackage.parse(folder: folder)
        #expect(book.toc.map(\.title) == ["NCX one", "NCX two"])
        #expect(book.toc.map(\.depth) == [0, 1])
    }

    @Test func resolvesRelativePaths() {
        #expect(EpubPackage.resolve("../images/a%20b.png", base: "OEBPS/text") == "OEBPS/images/a b.png")
        #expect(EpubPackage.resolve("./p.xhtml", base: "") == "p.xhtml")
    }

    @Test func refusesEntriesOutsideTheBook() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let evil = try TestEpub.zip(["../escape.txt": Data("x".utf8)])
        #expect(throws: BookRepository.BookError.self) { try BookRepository.unpack(evil, into: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appending(path: "escape.txt").path()))
    }
}

@Suite struct BookRepositoryTests {
    @Test func downloadsOnceThenOpensFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "books-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let epub = try TestEpub.zip(TestEpub.files())
        let downloads = Mutex(0)
        let repository = BookRepository(directory: directory) { _ in
            downloads.withLock { $0 += 1 }
            return epub
        }
        async let first = repository.book(chapterId: 359)
        async let second = repository.book(chapterId: 359)
        let (a, b) = try await (first, second)
        #expect(a.package == b.package)
        _ = try await repository.book(chapterId: 359)
        #expect(downloads.withLock { $0 } == 1)
        #expect(await repository.isDownloaded(chapterId: 359))
    }

    @Test func evictsLeastRecentlyOpenedBooks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "books-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let epub = try TestEpub.zip(TestEpub.files())
        let probe = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        try BookRepository.unpack(epub, into: probe)
        let bookSize = BookRepository.size(of: probe)
        try FileManager.default.removeItem(at: probe)
        let repository = BookRepository(directory: directory, limitBytes: bookSize * 2 + 10) { _ in epub }
        _ = try await repository.book(chapterId: 1)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await repository.book(chapterId: 2)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await repository.book(chapterId: 1)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await repository.book(chapterId: 3)
        #expect(await repository.isDownloaded(chapterId: 1))
        #expect(await !repository.isDownloaded(chapterId: 2), "book 2 was opened least recently")
        #expect(await repository.isDownloaded(chapterId: 3))
    }

    @Test func downloadedBooksSurviveEvictionAndClear() async throws {
        // A space in the path, like Application Support.
        let directory = FileManager.default.temporaryDirectory.appending(path: "books dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let epub = try TestEpub.zip(TestEpub.files())
        let probe = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        try BookRepository.unpack(epub, into: probe)
        let bookSize = BookRepository.size(of: probe)
        try FileManager.default.removeItem(at: probe)
        let repository = BookRepository(directory: directory, limitBytes: bookSize + 10) { _ in epub }
        _ = try await repository.book(chapterId: 1)
        await repository.pin(chapterId: 1)
        _ = try await repository.book(chapterId: 2)
        _ = try await repository.book(chapterId: 3)
        #expect(await repository.isDownloaded(chapterId: 1), "downloaded books aren't evicted")
        #expect(await !repository.isDownloaded(chapterId: 2))
        #expect(await repository.unpinnedBytes() == bookSize)
        await repository.clear()
        #expect(await repository.isDownloaded(chapterId: 1))
        #expect(await repository.isPinned(chapterId: 1))
        #expect(await !repository.isDownloaded(chapterId: 3))
        #expect(await repository.bytes(chapterId: 1) > 0)
        await repository.remove(chapterId: 1)
        #expect(await !repository.isDownloaded(chapterId: 1))
    }
}

@Suite struct BookProgressTests {
    @Test func newerPositionWinsAndFinishedBooksStartOver() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let local = LocalReadingProgress(chapterId: 1, seriesId: 1, volumeId: 1, libraryId: 4, page: 5, pages: 46,
                                         updatedAt: date, scrollId: "//body/div[1]/p[9]")
        let server = KavitaServerProgress(chapterId: 1, pageNum: 7, bookScrollId: "id(\"a\")", lastModifiedUtc: date.addingTimeInterval(60))
        #expect(ProgressSyncPolicy.startPosition(local: local, server: server, pages: 46) == (7, "id(\"a\")"))
        #expect(ProgressSyncPolicy.startPosition(local: local, server: nil, pages: 46) == (5, "//body/div[1]/p[9]"))
        let finished = KavitaServerProgress(chapterId: 1, pageNum: 46, bookScrollId: "//body/div[1]/p[1]", lastModifiedUtc: date.addingTimeInterval(60))
        #expect(ProgressSyncPolicy.startPosition(local: local, server: finished, pages: 46) == (0, nil))
    }

    @MainActor @Test func recorderSendsBookScrollId() throws {
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database)
        let chapter = ReaderChapter(chapterId: 359, volumeId: 359, seriesId: 34, libraryId: 4, pages: 46, title: "1", seriesTitle: "そら")
        let recorder = ReadingProgressRecorder(chapter: chapter, progressStore: ReadingProgressStore(database: database),
                                               outbox: outbox, syncNow: {})
        recorder.start(at: 3, scrollId: "//body/div[1]/p[1]")
        recorder.record(page: 3, scrollId: "//body/div[1]/p[1]")
        recorder.flush()
        #expect(try outbox.summary().pending == 0, "unchanged position isn't recorded")
        recorder.record(page: 3, scrollId: "//body/div[1]/p[8]")
        recorder.flush()
        let job = try #require(try outbox.claimDueJobs(kinds: [.kavitaProgress]).first)
        let payload = try job.job.decodePayload(KavitaProgressPayload.self)
        #expect(payload.pageNum == 3 && payload.bookScrollId == "//body/div[1]/p[8]")
        #expect(try ReadingProgressStore(database: database).progress(chapterId: 359)?.scrollId == "//body/div[1]/p[8]")
    }
}

@Suite struct BookWebTests {
    @MainActor @Test func schemeHandlerServesBookFilesOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "book-\(UUID().uuidString)")
        let handler = BookSchemeHandler(folder: folder)
        let url = try #require(BookSchemeHandler.url(chapterId: 359, path: "OEBPS/text/p 1.xhtml"))
        #expect(url.absoluteString == "kavitabook://359/OEBPS/text/p%201.xhtml")
        #expect(handler.file(for: url)?.path(percentEncoded: false) == folder.appending(path: "OEBPS/text/p 1.xhtml").standardizedFileURL.path(percentEncoded: false))
        #expect(handler.file(for: URL(string: "kavitabook://359/OEBPS/../../escape.txt")!) == nil)
        #expect(BookSchemeHandler.mimeType(URL(filePath: "a.xhtml")) == "application/xhtml+xml")
        #expect(BookSchemeHandler.mimeType(URL(filePath: "a.html")) == "text/html")
        #expect(BookSchemeHandler.mimeType(URL(filePath: "a.jpeg")) == "image/jpeg")
    }

    @Test func miningSourceNamesSeriesVolumeAndChapter() async throws {
        let chapter = ReaderChapter(chapterId: 359, volumeId: 359, seriesId: 34, libraryId: 4, pages: 46, title: "Volume 1", seriesTitle: "そら ソラ 空 ガーデン")
        #expect(BookMiningContext.miscInfo(chapter: chapter, section: "１ 空の庭へようこそ！")
            == "そら ソラ 空 ガーデン — Volume 1 · １ 空の庭へようこそ！")
        #expect(BookMiningContext.miscInfo(chapter: chapter, section: nil) == "そら ソラ 空 ガーデン — Volume 1")

        let cover = FileManager.default.temporaryDirectory.appending(path: "cover-\(UUID().uuidString).jpg")
        try Data([1, 2, 3]).write(to: cover)
        defer { try? FileManager.default.removeItem(at: cover) }
        let fromBook = BookMiningContext(cover: cover, fallbackCover: { Data([9]) }, miscInfo: "")
        #expect(await fromBook.pictureData() == Data([1, 2, 3]))
        let fromKavita = BookMiningContext(cover: nil, fallbackCover: { Data([9]) }, miscInfo: "")
        #expect(await fromKavita.pictureData() == Data([9]))
    }
}

@Suite struct BookTextIndexTests {
    @Test func countsLettersLikeHoshi() {
        let html = """
            <html><head><title>無視</title><style>p { color: red }</style></head>
            <body><p>　<ruby>吾輩<rp>(</rp><rt>わがはい</rt><rp>)</rp></ruby>は猫である。</p>
            <p>「……ＯＫ、々ー」A &amp; B 12</p><img src="a.png"/></body></html>
            """
        // 吾輩は猫である (7) + ＯＫ々ー (4) + AB12 (4): no punctuation, spaces, furigana or markup.
        #expect(BookTextIndex.count(html: html) == 15)
    }

    @Test func contentsPagesCountLikeAnyText() {
        // As in Hoshi: a contents page's titles are text too.
        let toc = #"<body><p><a href="a.xhtml">第一章　夢</a></p></body>"#
        #expect(BookTextIndex.count(html: toc) == 4)
    }

    @Test func sectionStartsAndCache() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try BookRepository.unpack(try TestEpub.zip(TestEpub.files()), into: folder)
        let package = try EpubPackage.parse(folder: folder)
        let index = BookTextIndex.load(folder: folder, package: package)
        #expect(index.sections == [7, 1, 7])
        #expect(index.total == 15 && index.start(of: 2) == 8)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: BookTextIndex.filename).path()))
    }
}

@Suite struct BookProgressRecordingTests {
    @Test func charactersReadFollowKavitaPages() {
        let index = BookTextIndex(sections: [0, 100, 50, 200])
        #expect(index.charactersRead(pagesRead: 0, pages: 4) == 0)
        #expect(index.charactersRead(pagesRead: 2, pages: 4) == 100)
        #expect(index.charactersRead(pagesRead: 4, pages: 4) == 350)
    }

    /// This device's own place reopens at its characters (a page can start inside a paragraph);
    /// Kavita's, or an older local place without characters, at the xpath.
    @MainActor @Test func startPlaceUsesTheDevicesCharacters() {
        let index = BookTextIndex(sections: [0, 100, 50, 200])
        let local = LocalReadingProgress(chapterId: 1, seriesId: 1, volumeId: 1, libraryId: 1, page: 3, pages: 4, updatedAt: .now,
                                         scrollId: "//p[2]", characters: 200)
        guard case let .place(xpath, fraction) = BookReaderModel.startPlace((3, "//p[2]"), local: local, index: index) else {
            Issue.record("expected a place"); return
        }
        #expect(xpath == "//p[2]" && fraction == 0.25)
        guard case .xpath("//p[9]") = BookReaderModel.startPlace((3, "//p[9]"), local: local, index: index) else {
            Issue.record("Kavita's newer place opens at its xpath"); return
        }
    }

    /// Opening a book and re-laying it out (settings, safe area) isn't reading: only positions
    /// after the reader moves reach Kavita, so reopening a finished volume can't mark it unread.
    @MainActor @Test func onlyPositionsAfterMovingAreRecorded() throws {
        let database = try AppDatabase.inMemory()
        let outbox = OutboxStore(database: database)
        let chapter = ReaderChapter(chapterId: 359, volumeId: 359, seriesId: 34, libraryId: 4, pages: 46, title: "1", seriesTitle: "そら")
        let model = BookReaderModel(
            chapter: chapter, nextChapter: nil,
            repository: BookRepository(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) { _ in Data() },
            settingsStore: BookReaderSettingsStore(database: database), progressStore: ReadingProgressStore(database: database),
            outbox: outbox, lookup: nil, serverProgress: { _ in throw URLError(.notConnectedToInternet) }, syncNow: {}
        )
        func position(_ xpath: String, moved: Bool) -> BookWebEvent {
            .position(page: 0, pages: 3, xpath: xpath, vertical: true, characters: 0, sectionCharacters: 10, moved: moved)
        }
        model.handle(position("//body/div[1]/svg[1]", moved: false))
        model.handle(position("//body/div[1]", moved: false))
        model.flushProgress()
        #expect(try outbox.summary().pending == 0)
        model.handle(position("//body/div[1]/p[3]", moved: true))
        model.flushProgress()
        #expect(try outbox.summary().pending == 1)
    }
}
