import Foundation

// DTOs for the endpoints the reader uses, verified against Kavita 0.9.1.7.
// Only the fields the app reads are declared; the cache keeps the full JSON.

public enum KavitaLibraryType {
    public static let manga = 0, comic = 1, book = 2, images = 3, lightNovel = 4, comicVine = 5
}

public enum KavitaFormat {
    public static let image = 0, archive = 1, unknown = 2, epub = 3, pdf = 4
}

public struct KavitaLibrary: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var type: Int

    public init(id: Int, name: String, type: Int) {
        self.id = id
        self.name = name
        self.type = type
    }

    /// Libraries of page images (the manga reader).
    public var isMangaReadable: Bool {
        [KavitaLibraryType.manga, KavitaLibraryType.comic, KavitaLibraryType.images, KavitaLibraryType.comicVine].contains(type)
    }

    /// Book and light-novel libraries hold EPUBs (the book reader).
    public var isBookLibrary: Bool {
        [KavitaLibraryType.book, KavitaLibraryType.lightNovel].contains(type)
    }
}

public struct KavitaSeries: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var localizedName: String?
    public var sortName: String?
    public var libraryId: Int
    public var format: Int
    public var pages: Int
    public var pagesRead: Int
    public var latestReadDate: Date?

    public init(id: Int, name: String, localizedName: String? = nil, sortName: String? = nil, libraryId: Int,
                format: Int, pages: Int, pagesRead: Int, latestReadDate: Date? = nil) {
        self.id = id
        self.name = name
        self.localizedName = localizedName
        self.sortName = sortName
        self.libraryId = libraryId
        self.format = format
        self.pages = pages
        self.pagesRead = pagesRead
        self.latestReadDate = latestReadDate
    }

    public var isEpub: Bool { format == KavitaFormat.epub }
    /// Kavita's own UI leads with `name`; `localizedName` is often another language's title.
    public var displayName: String { name }
}

public struct KavitaChapter: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var volumeId: Int
    public var number: String
    public var range: String?
    public var sortOrder: Double
    public var pages: Int
    public var pagesRead: Int
    public var isSpecial: Bool
    public var title: String?
    public var titleName: String?
    /// For books, Kavita's "word count": letters ÷ 5 (Kavita 0.9.1.7), so roughly a fifth of
    /// a Japanese book's characters. Yomu uses it only as an estimate before counting.
    public var wordCount: Int?
    /// The book's language code from its metadata ("ja").
    public var language: String?
    /// When this user's progress in it last changed on Kavita.
    public var lastReadingProgressUtc: Date?

    public init(id: Int, volumeId: Int, number: String, range: String? = nil, sortOrder: Double, pages: Int,
                pagesRead: Int, isSpecial: Bool = false, title: String? = nil, titleName: String? = nil,
                wordCount: Int? = nil, language: String? = nil) {
        self.id = id
        self.volumeId = volumeId
        self.number = number
        self.range = range
        self.sortOrder = sortOrder
        self.pages = pages
        self.pagesRead = pagesRead
        self.isSpecial = isSpecial
        self.title = title
        self.titleName = titleName
        self.wordCount = wordCount
        self.language = language
    }

    /// Kavita uses chapter number -100000 for a file that is a whole volume.
    public var isWholeVolume: Bool { number == "-100000" }
    public var isRead: Bool { pages > 0 && pagesRead >= pages }
}

public struct KavitaVolume: Codable, Equatable, Identifiable, Hashable, Sendable {
    /// Kavita's sentinel volume numbers.
    public static let looseLeafNumber = -100000.0
    public static let specialNumber = 100000.0

    public var id: Int
    public var seriesId: Int
    public var name: String
    public var number: Double
    public var pages: Int
    public var pagesRead: Int
    public var chapters: [KavitaChapter]

    public init(id: Int, seriesId: Int, name: String, number: Double, pages: Int, pagesRead: Int, chapters: [KavitaChapter]) {
        self.id = id
        self.seriesId = seriesId
        self.name = name
        self.number = number
        self.pages = pages
        self.pagesRead = pagesRead
        self.chapters = chapters
    }

    public var isLooseLeaf: Bool { number == Self.looseLeafNumber }
    public var isSpecials: Bool { number == Self.specialNumber }
}

public struct KavitaChapterInfo: Codable, Equatable, Sendable {
    public var seriesId: Int
    public var volumeId: Int
    public var libraryId: Int
    public var seriesName: String
    public var pages: Int
    public var isSpecial: Bool
    public var title: String?
    public var subtitle: String?
}

public struct KavitaPageDimension: Codable, Equatable, Sendable {
    public var pageNumber: Int
    public var width: Int
    public var height: Int
    public var isWide: Bool

    public init(pageNumber: Int, width: Int, height: Int, isWide: Bool) {
        self.pageNumber = pageNumber
        self.width = width
        self.height = height
        self.isWide = isWide
    }

    public var aspectRatio: Double { height > 0 ? Double(width) / Double(height) : 0.7 }
}

/// Body of `POST /api/Reader/progress`. `pageNum` is the number of pages read:
/// the on-screen page index, or `pages` once the last page is reached (verified:
/// `pages - 1` leaves the chapter unread; `pages` marks it read).
public struct KavitaProgressPayload: Codable, Equatable, Sendable {
    public var volumeId: Int
    public var chapterId: Int
    public var pageNum: Int
    public var seriesId: Int
    public var libraryId: Int
    public var bookScrollId: String?

    public init(volumeId: Int, chapterId: Int, pageNum: Int, seriesId: Int, libraryId: Int, bookScrollId: String? = nil) {
        self.volumeId = volumeId
        self.chapterId = chapterId
        self.pageNum = pageNum
        self.seriesId = seriesId
        self.libraryId = libraryId
        self.bookScrollId = bookScrollId
    }

    // Kavita expects an explicit null, so encode it rather than omitting the key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(volumeId, forKey: .volumeId)
        try container.encode(chapterId, forKey: .chapterId)
        try container.encode(pageNum, forKey: .pageNum)
        try container.encode(seriesId, forKey: .seriesId)
        try container.encode(libraryId, forKey: .libraryId)
        try container.encode(bookScrollId, forKey: .bookScrollId)
    }
}

/// `GET /api/Reader/get-progress`. A chapter never read comes back with
/// zeros and `lastModifiedUtc` of year 1, which decodes to `nil` here.
public struct KavitaServerProgress: Decodable, Equatable, Sendable {
    public var chapterId: Int
    public var pageNum: Int
    public var bookScrollId: String?
    public var lastModifiedUtc: Date?

    public init(chapterId: Int, pageNum: Int, bookScrollId: String? = nil, lastModifiedUtc: Date?) {
        self.chapterId = chapterId
        self.pageNum = pageNum
        self.bookScrollId = bookScrollId
        self.lastModifiedUtc = lastModifiedUtc
    }
}

public struct KavitaPagination: Decodable, Equatable, Sendable {
    public var currentPage: Int
    public var itemsPerPage: Int
    public var totalItems: Int
    public var totalPages: Int
}

public struct KavitaPage<Item: Sendable>: Sendable {
    public var items: [Item]
    public var pagination: KavitaPagination?

    public var hasMore: Bool {
        guard let pagination else { return false }
        return pagination.currentPage < pagination.totalPages
    }
}

enum KavitaJSON {
    /// Kavita sends UTC dates without a zone and with up to 7 fractional digits,
    /// e.g. `2026-06-18T03:17:26.1163252`. Year 1 means "unset" and becomes nil.
    static func parseDate(_ string: String) -> Date? {
        var text = string
        if text.hasSuffix("Z") { text.removeLast() }
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            fraction = Double("0" + text[dot...]) ?? 0
            text = String(text[..<dot])
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count == 6, parts[0] > 1 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                        hour: parts[3], minute: parts[4], second: parts[5])
        return calendar.date(from: components)?.addingTimeInterval(fraction)
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // Unset dates are represented as distantPast; optionals map them to nil below.
            return parseDate(string) ?? .distantPast
        }
        return decoder
    }

    /// Decodes each element of a JSON array, keeping its raw JSON for the cache.
    static func decodeEach<T: Decodable>(_ type: T.Type, from data: Data) throws -> [(T, Data)] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DecodingError.typeMismatch([Any].self, .init(codingPath: [], debugDescription: "Expected an array"))
        }
        let decoder = decoder
        return try array.map { element in
            let raw = try JSONSerialization.data(withJSONObject: element)
            return (try decoder.decode(T.self, from: raw), raw)
        }
    }
}

extension Date {
    /// Kavita "unset" dates (year 1) decode as `.distantPast`.
    var nilIfUnset: Date? { self == .distantPast ? nil : self }
}

extension KavitaServerProgress {
    enum CodingKeys: String, CodingKey { case chapterId, pageNum, bookScrollId, lastModifiedUtc }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterId = try container.decode(Int.self, forKey: .chapterId)
        pageNum = try container.decode(Int.self, forKey: .pageNum)
        bookScrollId = try container.decodeIfPresent(String.self, forKey: .bookScrollId)
        lastModifiedUtc = try container.decodeIfPresent(Date.self, forKey: .lastModifiedUtc)?.nilIfUnset
    }
}

extension KavitaSeries {
    enum CodingKeys: String, CodingKey {
        case id, name, localizedName, sortName, libraryId, format, pages, pagesRead, latestReadDate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        localizedName = try container.decodeIfPresent(String.self, forKey: .localizedName)
        sortName = try container.decodeIfPresent(String.self, forKey: .sortName)
        libraryId = try container.decode(Int.self, forKey: .libraryId)
        format = try container.decode(Int.self, forKey: .format)
        pages = try container.decode(Int.self, forKey: .pages)
        pagesRead = try container.decode(Int.self, forKey: .pagesRead)
        latestReadDate = try container.decodeIfPresent(Date.self, forKey: .latestReadDate)?.nilIfUnset
    }
}

/// Kavita's series metadata, reduced to what the series page shows.
public struct KavitaSeriesMetadata: Decodable, Equatable, Sendable {
    public struct Named: Decodable, Equatable, Sendable {
        public var title: String?
        public var name: String?
    }

    public var summary: String?
    public var genres: [Named]
    public var writers: [Named]

    enum CodingKeys: String, CodingKey { case summary, genres, writers }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        genres = try container.decodeIfPresent([Named].self, forKey: .genres) ?? []
        writers = try container.decodeIfPresent([Named].self, forKey: .writers) ?? []
    }

    /// The summary as plain text (Kavita keeps the HTML from the book or its source).
    public var plainSummary: String? {
        guard let summary else { return nil }
        let text = summary
            .replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public var genreNames: [String] { genres.compactMap(\.title) }
    public var writerNames: [String] { writers.compactMap(\.name) }
}

/// A series in Kavita's search results.
public struct KavitaSearchSeries: Decodable, Equatable, Hashable, Sendable, Identifiable {
    public var seriesId: Int
    public var name: String
    public var libraryId: Int
    public var libraryName: String?
    public var id: Int { seriesId }
}

struct KavitaSearchResult: Decodable {
    var series: [KavitaSearchSeries]
}
