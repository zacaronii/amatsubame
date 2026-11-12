import Core
import Foundation
import KavitaKit
import Network
import Observation
import Readers

/// Counts Japanese books' characters (Hoshi Reader's rule) so the library's progress never
/// comes from Kavita's figures: its word count is letters ÷ 5 and its pages are sections.
/// Each volume is counted from the book when it's on the device, else from Kavita's text
/// (`bookPage`: the HTML of each section, no images); only the counts are kept (`BookLengths`).
///
/// Light novel libraries count in full; other book libraries only volumes Kavita tags Japanese.
/// The first count of the whole library starts from Settings; after that, new and changed
/// volumes of series already counted are counted after a library refresh on unmetered networks,
/// and a series page counts its own missing volumes when it opens.
@MainActor @Observable
final class BookLengthCounter {
    /// What a full count would do: volumes to count and roughly how much text that is.
    struct Survey: Equatable {
        var counted: Int
        var toCount: Int
        var estimatedBytes: Int
    }

    private(set) var survey: Survey?
    /// What's being counted: the whole library (the button), or new volumes after a refresh.
    enum Job { case library, newVolumes }
    private(set) var job: Job?
    private(set) var isSurveying = false
    private(set) var isCounting = false
    private(set) var done = 0
    private(set) var toDo = 0
    private(set) var bytes = 0
    private(set) var problem: String?
    /// Stopped from Settings before every volume was counted.
    private(set) var stopped = false

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The volumes the survey covers, to keep its rows exact as counts are saved.
    @ObservationIgnored private var surveyed: [Volume] = []
    /// Bumped for each job, so a stopped one's last volume doesn't touch the next one's progress.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored nonisolated(unsafe) private var unmetered = false

    /// Sections fetched at once.
    static let parallelSections = 3
    /// What a section costs to fetch, on average: Kavita sends each section with the book's
    /// whole stylesheet, compressed (measured on a light novel series: 25 MB for 40 volumes,
    /// about 11 KB a section).
    static let bytesPerSection = 12_000

    init(environment: AppEnvironment) {
        self.environment = environment
        path.pathUpdateHandler = { [weak self] path in
            self?.unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
        }
        path.start(queue: DispatchQueue(label: "BookLengthCounter.path"))
    }

    /// One volume to count.
    struct Volume: Sendable {
        var chapter: KavitaChapter
        var seriesId: Int
    }

    // MARK: Which volumes

    /// Japanese books: every EPUB volume in a light novel library, and volumes Kavita tags
    /// Japanese in other book libraries.
    static func counts(_ chapter: KavitaChapter, library: KavitaLibrary) -> Bool {
        library.type == KavitaLibraryType.lightNovel || chapter.language?.lowercased().hasPrefix("ja") == true
    }

    /// Every Japanese EPUB volume in the readable book libraries (refreshing the series and
    /// volume lists on the way, which the library uses too).
    private func japaneseVolumes(using client: KavitaClient, onlyCountedSeries: Bool) async throws -> [Volume] {
        let repository = environment.kavitaLibrary
        let libraries = try await repository.refreshLibraries(using: client).filter(\.isBookLibrary)
        let counted = Set(((try? environment.bookLengths.all()) ?? [:]).values.map(\.seriesId))
        var volumes: [Volume] = []
        for library in libraries {
            for series in try await repository.refreshSeries(libraryId: library.id, using: client) where series.isEpub {
                if onlyCountedSeries, !counted.contains(series.id) { continue }
                let contents = KavitaSeriesContents(volumes: try await repository.refreshVolumes(seriesId: series.id, using: client))
                for chapter in contents.readingOrder + contents.specials where Self.counts(chapter, library: library) {
                    volumes.append(Volume(chapter: chapter, seriesId: series.id))
                }
            }
        }
        return volumes
    }

    private func needsCounting(_ volumes: [Volume]) -> [Volume] {
        let lengths = (try? environment.bookLengths.all()) ?? [:]
        return volumes.filter { lengths[$0.chapter.id]?.isStale(pages: $0.chapter.pages, wordCount: $0.chapter.wordCount) ?? true }
    }

    // MARK: Settings

    /// What a full count would fetch (Settings shows it before the button).
    func refreshSurvey() async {
        guard !isSurveying, let client = environment.kavitaClient() else { return }
        isSurveying = true
        defer { isSurveying = false }
        do {
            surveyed = try await japaneseVolumes(using: client, onlyCountedSeries: false)
            updateSurvey()
            problem = nil
        } catch {
            if !error.isCancellation { problem = error.localizedDescription }
        }
    }

    /// The survey's rows from the counts saved now (they can't pass the total).
    private func updateSurvey() {
        let missing = needsCounting(surveyed)
        survey = Survey(counted: surveyed.count - missing.count, toCount: missing.count,
                        estimatedBytes: missing.reduce(0) { $0 + $1.chapter.pages } * Self.bytesPerSection)
    }

    /// The button: counts every Japanese volume not counted yet (taking over from a count of
    /// new volumes). Keeps going while Yomu is open; stopping keeps what's counted, and the next
    /// run picks up the rest.
    func countLibrary() {
        guard job != .library else { return }
        stopped = false
        start(.library) { client in
            try await self.japaneseVolumes(using: client, onlyCountedSeries: false)
        }
    }

    /// Stop: what's counted stays; the next count picks up the rest.
    func cancel() {
        task?.cancel()
        stopped = true
        problem = nil
    }

    /// One count at a time: a new job replaces the one running.
    private func start(_ kind: Job, volumes: @escaping (KavitaClient) async throws -> [Volume]) {
        task?.cancel()
        generation += 1
        let generation = generation
        job = kind
        isCounting = true
        (done, toDo, bytes, problem) = (0, 0, 0, nil)
        task = Task {
            defer {
                if self.generation == generation { (job, isCounting, task) = (nil, false, nil) }
            }
            guard let client = environment.kavitaClient() else { return }
            do {
                let list = needsCounting(try await volumes(client))
                guard !Task.isCancelled else { return }
                await run(list, using: client, generation: generation)
            } catch {
                if !error.isCancellation, !Task.isCancelled { problem = error.localizedDescription }
            }
            if kind == .library, !Task.isCancelled { await refreshSurvey() }
        }
    }

    // MARK: Automatic

    /// After a library refresh: new and changed volumes of series already counted, on an
    /// unmetered network (the first full count is the button's).
    func countNewVolumes() {
        guard job == nil, unmetered, (try? environment.bookLengths.all().isEmpty) == false else { return }
        start(.newVolumes) { client in
            try await self.japaneseVolumes(using: client, onlyCountedSeries: true)
        }
    }

    /// A series page's volumes not counted yet, right away (unless a count is running, which
    /// gets to them).
    func count(_ chapters: [KavitaChapter], seriesId: Int) async {
        guard job == nil, let client = environment.kavitaClient() else { return }
        let library = (try? environment.kavitaLibrary.cachedSeries(id: seriesId))
            .flatMap { series in (try? environment.kavitaLibrary.cachedLibraries())?.first { $0.id == series.libraryId } }
        let volumes = chapters.filter { chapter in library.map { Self.counts(chapter, library: $0) } ?? false }
            .map { Volume(chapter: $0, seriesId: seriesId) }
        for volume in needsCounting(volumes) {
            if Task.isCancelled { return }
            if let length = await count(volume, using: client) { try? environment.bookLengths.save(length) }
        }
        if !surveyed.isEmpty { updateSurvey() }
    }

    // MARK: Counting

    private func run(_ volumes: [Volume], using client: KavitaClient, generation: Int) async {
        toDo = volumes.count
        for volume in volumes {
            if Task.isCancelled || self.generation != generation { return }
            // Counted meanwhile (a series page, the book opened): skip it.
            if !needsCounting([volume]).isEmpty {
                if let length = await count(volume, using: client) {
                    guard self.generation == generation else { return }
                    try? environment.bookLengths.save(length)
                    if !surveyed.isEmpty { updateSurvey() }
                } else if problem == nil, !Task.isCancelled {
                    problem = "Couldn't count every volume. Try again later."
                }
            }
            if self.generation == generation { done += 1 }
        }
    }

    /// One volume: from its unpacked book when it's on the device, else from Kavita's text.
    private func count(_ volume: Volume, using client: KavitaClient) async -> BookLength? {
        let chapter = volume.chapter
        if let index = await environment.books.cachedTextIndex(chapterId: chapter.id), index.sections.count == chapter.pages {
            return BookLength(chapterId: chapter.id, seriesId: volume.seriesId, sections: index.sections,
                              kavitaWordCount: chapter.wordCount, kavitaPages: chapter.pages, countedAt: .now)
        }
        guard chapter.pages > 0 else { return nil }
        var sections = [Int](repeating: 0, count: chapter.pages)
        var fetched = 0
        let pages = Array(0..<chapter.pages)
        do {
            try await withThrowingTaskGroup(of: (Int, Int, Int).self) { group in
                var next = 0
                func add() {
                    guard next < pages.count else { return }
                    let page = pages[next]
                    next += 1
                    group.addTask {
                        let html = try await client.bookPage(chapterId: chapter.id, page: page)
                        return (page, BookTextIndex.count(html: html), Self.transferSize(html))
                    }
                }
                for _ in 0..<Self.parallelSections { add() }
                while let (page, count, size) = try await group.next() {
                    sections[page] = count
                    fetched += size
                    add()
                }
            }
        } catch {
            bytes += fetched
            return nil
        }
        bytes += fetched
        return BookLength(chapterId: chapter.id, seriesId: volume.seriesId, sections: sections,
                          kavitaWordCount: chapter.wordCount, kavitaPages: chapter.pages, countedAt: .now)
    }

    /// About what a section took to download: Kavita sends it compressed (without a length),
    /// and the counter only sees the text, so this compresses it the same way to measure.
    nonisolated static func transferSize(_ html: String) -> Int {
        let data = Data(html.utf8)
        return ((try? (data as NSData).compressed(using: .zlib)) as Data?)?.count ?? data.count
    }
}
