import Core
import Foundation

// Verified against Kavita 0.9.1.23 (2026-11-22) with a test account; create → list → delete each:
// - Annotations (highlights and notes, Kavita 0.8.8 and later): `POST /api/Annotation/create`
//   and `/update` take and return the whole row; update changes only the comment, colour slot
//   and spoiler flag. `DELETE /api/Annotation?annotationId=`. Lists: `GET /api/Annotation/all?chapterId=`
//   and `/all-for-series?seriesId=`. An update or delete of an annotation that's gone is a 400
//   (not a 404); `GET /api/Annotation/{id}` is then a 404. A server without annotations answers
//   the routes with 404.
//   Who else sees them is the user's own Kavita setting (Share Annotations, off by default), not a
//   field of the row; the lists can hold other users' annotations when they share theirs and
//   this user views them, so only rows owned by this user are taken.
// - Personal table of contents (a book's bookmarks): `POST /api/Reader/create-ptoc` (empty 200),
//   `GET /api/Reader/ptoc?chapterId=`, `DELETE /api/Reader/ptoc?chapterId&pageNum&title`
//   (by page and title; 200 also when there's nothing to delete).
// - Page bookmarks: `POST /api/Reader/bookmark` and `/unbookmark` by chapter and page (200 also
//   when there's nothing to remove), `GET /api/Reader/series-bookmarks?seriesId=`. They need the
//   Bookmark role, and Kavita keeps a copy of the page image in its bookmarks folder.

/// A highlight (and its note) as Kavita has it.
public struct KavitaAnnotation: Codable, Equatable, Sendable {
    public var id: Int
    public var xPath: String
    public var endingXPath: String?
    public var selectedText: String?
    public var comment: String?
    public var commentHtml: String?
    public var commentPlainText: String?
    public var highlightCount: Int
    public var containsSpoiler: Bool
    public var pageNumber: Int
    public var selectedSlotIndex: Int
    public var likes: [Int]?
    public var chapterId: Int
    public var volumeId: Int
    public var seriesId: Int
    public var libraryId: Int
    public var ownerUserId: Int

    public init(id: Int = 0, xPath: String, endingXPath: String?, selectedText: String?, comment: String? = nil,
                commentHtml: String? = nil, commentPlainText: String? = nil, highlightCount: Int, containsSpoiler: Bool = false,
                pageNumber: Int, selectedSlotIndex: Int, likes: [Int]? = [], chapterId: Int, volumeId: Int, seriesId: Int,
                libraryId: Int, ownerUserId: Int = 0) {
        self.id = id
        self.xPath = xPath
        self.endingXPath = endingXPath
        self.selectedText = selectedText
        self.comment = comment
        self.commentHtml = commentHtml
        self.commentPlainText = commentPlainText
        self.highlightCount = highlightCount
        self.containsSpoiler = containsSpoiler
        self.pageNumber = pageNumber
        self.selectedSlotIndex = selectedSlotIndex
        self.likes = likes
        self.chapterId = chapterId
        self.volumeId = volumeId
        self.seriesId = seriesId
        self.libraryId = libraryId
        self.ownerUserId = ownerUserId
    }

    /// What a highlight row sends. Nothing about who may see it: that's the user's own setting
    /// in Kavita, and the spoiler flag (which only matters to others) stays off.
    public init(_ mark: ReaderMark) {
        let text = mark.text ?? ""
        self.init(id: mark.serverId ?? 0, xPath: mark.xpath ?? "", endingXPath: mark.endXPath ?? mark.xpath, selectedText: text,
                  comment: mark.note, commentHtml: mark.note.map(Self.html), commentPlainText: mark.note,
                  highlightCount: max(text.count, 1), pageNumber: mark.page, selectedSlotIndex: min(max(mark.slot, 0), 4),
                  chapterId: mark.chapterId, volumeId: mark.volumeId, seriesId: mark.seriesId, libraryId: mark.libraryId)
    }

    /// A plain note as the rich text Kavita keeps (a paragraph per line).
    static func html(_ note: String) -> String {
        note.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            "<p>" + line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;") + "</p>"
        }.joined()
    }

    public func mark(account: String) -> ReaderMark {
        let note = (commentPlainText ?? comment).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return ReaderMark(account: account, kind: .highlight, serverId: id, libraryId: libraryId, seriesId: seriesId, volumeId: volumeId,
                          chapterId: chapterId, page: pageNumber, xpath: xPath, endXPath: endingXPath, text: selectedText, note: note,
                          slot: selectedSlotIndex, state: .synced, createdAt: .distantPast, updatedAt: .distantPast)
    }
}

/// A book's bookmark: Kavita's personal table of contents.
public struct KavitaPersonalToC: Codable, Equatable, Sendable {
    public var id: Int?
    public var chapterId: Int
    public var pageNumber: Int
    public var title: String
    public var bookScrollId: String?
    public var selectedText: String?

    public func mark(account: String, libraryId: Int, seriesId: Int, volumeId: Int) -> ReaderMark {
        ReaderMark(account: account, kind: .bookBookmark, serverId: id, libraryId: libraryId, seriesId: seriesId, volumeId: volumeId,
                   chapterId: chapterId, page: pageNumber, xpath: bookScrollId, text: selectedText, title: title, state: .synced,
                   createdAt: .distantPast, updatedAt: .distantPast)
    }
}

/// Body of `POST /api/Reader/create-ptoc`.
public struct KavitaCreatePersonalToC: Codable, Equatable, Sendable {
    public var chapterId: Int
    public var volumeId: Int
    public var seriesId: Int
    public var libraryId: Int
    public var pageNumber: Int
    public var title: String
    public var bookScrollId: String?
    public var selectedText: String?

    public init(_ mark: ReaderMark) {
        chapterId = mark.chapterId
        volumeId = mark.volumeId
        seriesId = mark.seriesId
        libraryId = mark.libraryId
        pageNumber = mark.page
        title = mark.title ?? "Page \(mark.page + 1)"
        bookScrollId = mark.xpath
        selectedText = mark.text
    }
}

/// A bookmarked manga page, as listed and as sent to `bookmark`/`unbookmark`.
public struct KavitaPageBookmark: Codable, Equatable, Sendable {
    public var id: Int?
    public var page: Int
    public var chapterId: Int
    public var volumeId: Int
    public var seriesId: Int

    public init(id: Int? = nil, page: Int, chapterId: Int, volumeId: Int, seriesId: Int) {
        self.id = id
        self.page = page
        self.chapterId = chapterId
        self.volumeId = volumeId
        self.seriesId = seriesId
    }

    public init(_ mark: ReaderMark) {
        self.init(page: mark.page, chapterId: mark.chapterId, volumeId: mark.volumeId, seriesId: mark.seriesId)
    }

    public func mark(account: String, libraryId: Int) -> ReaderMark {
        ReaderMark(account: account, kind: .pageBookmark, serverId: id, libraryId: libraryId, seriesId: seriesId, volumeId: volumeId,
                   chapterId: chapterId, page: page, state: .synced, createdAt: .distantPast, updatedAt: .distantPast)
    }

    enum CodingKeys: String, CodingKey { case id, page, chapterId, volumeId, seriesId }
}

extension KavitaClient {
    // MARK: Annotations (call the writes only from the outbox handler)

    public func annotations(seriesId: Int) async throws(ConnectionError) -> [KavitaAnnotation] {
        try await http.decode([KavitaAnnotation].self, from: request("api/Annotation/all-for-series", query: [.init(name: "seriesId", value: String(seriesId))]),
                              decoder: KavitaJSON.decoder)
    }

    /// Nil when there's no such annotation (removed).
    public func annotation(id: Int) async throws(ConnectionError) -> KavitaAnnotation? {
        do {
            return try await http.decode(KavitaAnnotation.self, from: request("api/Annotation/\(id)"), decoder: KavitaJSON.decoder)
        } catch .server(status: 404) {
            return nil
        }
    }

    public func createAnnotation(_ annotation: KavitaAnnotation) async throws(ConnectionError) -> KavitaAnnotation {
        try await http.decode(KavitaAnnotation.self, from: jsonRequest("POST", "api/Annotation/create", body: annotation), decoder: KavitaJSON.decoder)
    }

    public func updateAnnotation(_ annotation: KavitaAnnotation) async throws(ConnectionError) -> KavitaAnnotation {
        try await http.decode(KavitaAnnotation.self, from: jsonRequest("POST", "api/Annotation/update", body: annotation), decoder: KavitaJSON.decoder)
    }

    public func deleteAnnotation(id: Int) async throws(ConnectionError) {
        var request = request("api/Annotation", query: [.init(name: "annotationId", value: String(id))])
        request.httpMethod = "DELETE"
        _ = try await http.send(request)
    }

    // MARK: Personal table of contents

    public func personalToC(chapterId: Int) async throws(ConnectionError) -> [KavitaPersonalToC] {
        try await http.decode([KavitaPersonalToC].self, from: request("api/Reader/ptoc", query: [.init(name: "chapterId", value: String(chapterId))]),
                              decoder: KavitaJSON.decoder)
    }

    public func createPersonalToC(_ entry: KavitaCreatePersonalToC) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/Reader/create-ptoc", body: entry))
    }

    public func deletePersonalToC(chapterId: Int, page: Int, title: String) async throws(ConnectionError) {
        var request = request("api/Reader/ptoc", query: [
            .init(name: "chapterId", value: String(chapterId)), .init(name: "pageNum", value: String(page)), .init(name: "title", value: title),
        ])
        request.httpMethod = "DELETE"
        _ = try await http.send(request)
    }

    // MARK: Page bookmarks

    public func pageBookmarks(seriesId: Int) async throws(ConnectionError) -> [KavitaPageBookmark] {
        try await http.decode([KavitaPageBookmark].self, from: request("api/Reader/series-bookmarks", query: [.init(name: "seriesId", value: String(seriesId))]),
                              decoder: KavitaJSON.decoder)
    }

    public func bookmarkPage(_ bookmark: KavitaPageBookmark) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/Reader/bookmark", body: bookmark))
    }

    public func unbookmarkPage(_ bookmark: KavitaPageBookmark) async throws(ConnectionError) {
        _ = try await http.send(jsonRequest("POST", "api/Reader/unbookmark", body: bookmark))
    }
}
