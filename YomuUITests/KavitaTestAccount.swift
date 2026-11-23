import XCTest

/// The test account's bookmarks and highlights on Kavita, read and cleaned up from the test
/// runner (`UITEST_KAVITA_URL`, `UITEST_KAVITA_KEY`). Tests that make marks take a snapshot
/// first and put back what they made in teardown, so a run that fails halfway leaves nothing.
struct KavitaTestAccount {
    let base: URL
    let key: String

    init() throws {
        let env = ProcessInfo.processInfo.environment
        base = try XCTUnwrap(env["UITEST_KAVITA_URL"].flatMap(URL.init(string:)))
        key = try XCTUnwrap(env["UITEST_KAVITA_KEY"])
    }

    /// One request, waited for (test runner code, off the app).
    @discardableResult
    func call(_ method: String, _ path: String, query: [String: String] = [:], body: String? = nil) throws -> Any? {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = body.map { Data($0.utf8) }
        nonisolated(unsafe) var result: Result<Any?, any Error> = .failure(URLError(.timedOut))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                result = .failure(URLError(.badServerResponse))
                return
            }
            guard let data, !data.isEmpty else { result = .success(nil); return }
            // Some writes answer with plain text ("Reading List deleted"); reads are always JSON,
            // and a read that isn't fails where it's checked for a list or an object.
            if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("json") == false {
                result = .success(String(decoding: data, as: UTF8.self))
                return
            }
            do {
                result = .success(try JSONSerialization.jsonObject(with: data))
            } catch {
                result = .failure(error)
            }
        }.resume()
        // No answer in time is a failure, never an empty list.
        guard done.wait(timeout: .now() + 30) == .success else { throw URLError(.timedOut) }
        return try result.get()
    }

    /// A list as the read must give it: anything else fails the test rather than reading as empty.
    func list(_ value: Any?, _ what: String) throws -> [[String: Any]] {
        guard let list = value as? [[String: Any]] else { throw UnexpectedAnswer(what: what) }
        return list
    }

    /// The test account's own id (Kavita's lists can hold other users' shared annotations).
    func userId() throws -> Int {
        try XCTUnwrap((try call("GET", "api/Account") as? [String: Any])?["id"] as? Int, "the test account's id")
    }

    /// The test account's own annotations.
    func annotations() throws -> [[String: Any]] {
        let me = try userId()
        return try list(try call("POST", "api/Annotation/all-filtered", query: ["pageNumber": "1", "pageSize": "100"], body: "{}"), "annotations")
            .filter { $0["ownerUserId"] as? Int == me }
    }

    func pageBookmarks() throws -> [[String: Any]] {
        try list(try call("POST", "api/Reader/all-bookmarks", body: #"{"statements":[],"combination":1,"limitTo":0}"#), "page bookmarks")
    }

    /// The series in the test account's Want to Read.
    func wantToRead() throws -> Set<Int> {
        Set(try list(try call("POST", "api/want-to-read/v2", query: ["pageNumber": "1", "pageSize": "200"],
                              body: #"{"statements":[],"combination":1,"limitTo":0}"#), "Want to Read").compactMap { $0["id"] as? Int })
    }

    /// The only title a test gives a collection it makes.
    static let testCollectionTitle = "amatsubame-uitest"

    /// The test account's own collections' titles.
    func collectionTitles() throws -> [Int: String] {
        var titles: [Int: String] = [:]
        for collection in try list(try call("GET", "api/Collection", query: ["ownedOnly": "true"]), "collections") {
            guard let id = collection["id"] as? Int, let title = collection["title"] as? String else { throw UnexpectedAnswer(what: "a collection") }
            titles[id] = title
        }
        return titles
    }

    /// The test account's own collections, each with its series.
    func collections() throws -> [Int: Set<Int>] {
        var result: [Int: Set<Int>] = [:]
        for collection in try list(try call("GET", "api/Collection", query: ["ownedOnly": "true"]), "collections") {
            guard let id = collection["id"] as? Int else { throw UnexpectedAnswer(what: "a collection's id") }
            let series = try list(try call("POST", "api/Series/v2", query: ["pageNumber": "1", "pageSize": "500"],
                                           body: #"{"statements":[{"field":7,"comparison":0,"value":"\#(id)"}],"combination":1,"limitTo":0}"#),
                                  "a collection's series")
            result[id] = Set(series.compactMap { $0["id"] as? Int })
        }
        return result
    }

    /// The test account's own reading lists, each with its items' chapters in order.
    func readingLists() throws -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for list in try list(try call("POST", "api/ReadingList/lists", query: ["includePromoted": "false"], body: "{}"), "reading lists") {
            guard let id = list["id"] as? Int else { throw UnexpectedAnswer(what: "a reading list's id") }
            let items = try self.list(try call("GET", "api/ReadingList/items", query: ["readingListId": String(id)]), "a reading list's items")
            result[id] = items.compactMap { $0["chapterId"] as? Int }
        }
        return result
    }

    func readingListTitles() throws -> [Int: String] {
        var titles: [Int: String] = [:]
        for list in try list(try call("POST", "api/ReadingList/lists", query: ["includePromoted": "false"], body: "{}"), "reading lists") {
            guard let id = list["id"] as? Int, let title = list["title"] as? String else { throw UnexpectedAnswer(what: "a reading list") }
            titles[id] = title
        }
        return titles
    }

    /// The pages read in a chapter (Kavita's progress), to check a test changed none.
    func progress(chapterId: Int) throws -> Int {
        try XCTUnwrap((try call("GET", "api/Reader/get-progress", query: ["chapterId": String(chapterId)]) as? [String: Any])?["pageNum"] as? Int)
    }

    /// A series' id, found by its name.
    func seriesId(named name: String) throws -> Int {
        let found = try XCTUnwrap(try call("GET", "api/Search/search", query: ["queryString": name]) as? [String: Any], "the search")
        let series = try list(found["series"], "the search's series").first { $0["name"] as? String == name }
        return try XCTUnwrap(series?["seriesId"] as? Int, "the series")
    }

    /// Pages read and pages per chapter of a series (Kavita's progress).
    func pagesRead(seriesId: Int) throws -> [Int: (read: Int, pages: Int)] {
        var result: [Int: (read: Int, pages: Int)] = [:]
        for volume in try list(try call("GET", "api/Series/volumes", query: ["seriesId": String(seriesId)]), "the volumes") {
            for chapter in try list(volume["chapters"], "a volume's chapters") {
                guard let id = chapter["id"] as? Int, let read = chapter["pagesRead"] as? Int, let pages = chapter["pages"] as? Int else {
                    throw UnexpectedAnswer(what: "a chapter's progress")
                }
                result[id] = (read, pages)
            }
        }
        return result
    }

    /// How many entries the account's own reading history has for a series.
    func readingHistoryCount(seriesId: Int) throws -> Int {
        let items = try list(try call("GET", "api/Stats/reading-history/series/\(seriesId)",
                                      query: ["tzId": "UTC", "pageNumber": "1", "pageSize": "200"]), "the reading history")
        return items.count
    }

    /// A series' chapters, found by its name.
    func chapters(series name: String) throws -> [Int] {
        let found = try XCTUnwrap(try call("GET", "api/Search/search", query: ["queryString": name]) as? [String: Any], "the search")
        let series = try list(found["series"], "the search's series").first { $0["name"] as? String == name }
        let id = try XCTUnwrap(series?["seriesId"] as? Int, "the series")
        let volumes = try list(try call("GET", "api/Series/volumes", query: ["seriesId": String(id)]), "the volumes")
        return try volumes.flatMap { try list($0["chapters"], "a volume's chapters").compactMap { $0["id"] as? Int } }
    }

    /// A series' book bookmarks (Kavita's personal table of contents), as chapter, page and title.
    func bookBookmarks(series name: String) throws -> [BookBookmark] {
        try chapters(series: name).flatMap { chapter in
            try list(try call("GET", "api/Reader/ptoc", query: ["chapterId": String(chapter)]), "the book's bookmarks").compactMap { entry in
                guard let page = entry["pageNumber"] as? Int, let title = entry["title"] as? String else { return nil }
                return BookBookmark(chapter: chapter, page: page, title: title)
            }
        }
    }

    struct UnexpectedAnswer: Error, CustomStringConvertible {
        var what: String
        var description: String { "Kavita's answer for \(what) wasn't the list expected." }
    }

    struct BookBookmark: Hashable {
        var chapter: Int
        var page: Int
        var title: String
    }

    /// What's there now; `restore()` removes whatever was added since.
    /// `progressOf`: a series whose reading progress the test may change (marks only, on chapters
    /// unread here): restore marks them unread again. Kavita can't delete a progress row or put
    /// back its date, so a 0-page row and a moved last-read date are left.
    func snapshot(bookSeries: String? = nil, progressOf: Int? = nil) throws -> Snapshot {
        Snapshot(account: self, bookSeries: bookSeries, progressSeries: progressOf,
                 progress: try progressOf.map { try pagesRead(seriesId: $0).mapValues(\.read) } ?? [:],
                 annotations: Set(try annotations().compactMap { $0["id"] as? Int }),
                 pageBookmarks: Set(try pageBookmarks().compactMap { $0["id"] as? Int }),
                 bookBookmarks: Set(try bookSeries.map { try bookBookmarks(series: $0) } ?? []),
                 wantToRead: try wantToRead(), collections: try collections(), readingLists: try readingLists())
    }

    struct Snapshot {
        let account: KavitaTestAccount
        let bookSeries: String?
        let progressSeries: Int?
        let progress: [Int: Int]
        let annotations: Set<Int>
        let pageBookmarks: Set<Int>
        let bookBookmarks: Set<BookBookmark>
        let wantToRead: Set<Int>
        let collections: [Int: Set<Int>]
        let readingLists: [Int: [Int]]

        /// Removes the marks made since the snapshot. Returns what's still left over.
        @discardableResult
        func restore() throws -> String? {
            if let series = progressSeries {
                let changed = try account.pagesRead(seriesId: series).filter { progress[$0.key] == 0 && $0.value.read != 0 }.map(\.key)
                if !changed.isEmpty {
                    try account.call("POST", "api/Reader/mark-multiple-unread",
                                     body: #"{"seriesId":\#(series),"volumeIds":[],"chapterIds":\#(changed)}"#)
                }
                if try account.pagesRead(seriesId: series).mapValues(\.read) != progress { return "reading progress differs from before the test" }
            }
            for annotation in try account.annotations() {
                guard let id = annotation["id"] as? Int, !annotations.contains(id) else { continue }
                try account.call("DELETE", "api/Annotation", query: ["annotationId": String(id)])
            }
            for bookmark in try account.pageBookmarks() {
                guard let id = bookmark["id"] as? Int, !pageBookmarks.contains(id) else { continue }
                let body = ["page", "chapterId", "volumeId", "seriesId"].compactMap { key in (bookmark[key] as? Int).map { "\"\(key)\":\($0)" } }
                try account.call("POST", "api/Reader/unbookmark", body: "{" + body.joined(separator: ",") + "}")
            }
            if let bookSeries {
                for entry in try account.bookBookmarks(series: bookSeries) where !bookBookmarks.contains(entry) {
                    try account.call("DELETE", "api/Reader/ptoc", query: ["chapterId": String(entry.chapter), "pageNum": String(entry.page), "title": entry.title])
                }
            }
            // Want to Read both ways: added ones out, removed ones back.
            let wantedNow = try account.wantToRead()
            let added = wantedNow.subtracting(wantToRead), removed = wantToRead.subtracting(wantedNow)
            if !added.isEmpty {
                try account.call("POST", "api/want-to-read/remove-series", body: #"{"seriesIds":\#(Array(added))}"#)
            }
            if !removed.isEmpty {
                try account.call("POST", "api/want-to-read/add-series", body: #"{"seriesIds":\#(Array(removed))}"#)
            }
            if try account.wantToRead() != wantToRead { return "Want to Read differs from before the test" }
            // Collections the tests made go (only those, by their made-up title); any other new one,
            // and any that was there and changed, fails the run instead and is left alone.
            let made = try account.collectionTitles().filter { collections[$0.key] == nil && $0.value == KavitaTestAccount.testCollectionTitle }.map(\.key)
            if !made.isEmpty {
                try account.call("POST", "api/Collection/delete-multiple", body: #"{"collectionIds":\#(made)}"#)
            }
            // Reading lists the same way.
            let madeLists = try account.readingListTitles().filter { readingLists[$0.key] == nil && $0.value == KavitaTestAccount.testCollectionTitle }.map(\.key)
            for id in madeLists { try account.call("DELETE", "api/ReadingList", query: ["readingListId": String(id)]) }
            let listsNow = try account.readingLists()
            if listsNow != readingLists {
                return "reading lists differ from before the test: had \(readingLists.count) (items \(readingLists.values.map(\.count))), now \(listsNow.count) (items \(listsNow.values.map(\.count)))"
            }
            let now = try account.collections()
            if now != collections {
                return "collections differ from before the test: had \(collections.count) (series \(collections.values.map(\.count))), now \(now.count) (series \(now.values.map(\.count)))"
            }
            let left = (try account.annotations().count - annotations.count, try account.pageBookmarks().count - pageBookmarks.count,
                        try bookSeries.map { try account.bookBookmarks(series: $0).count - bookBookmarks.count } ?? 0)
            return left == (0, 0, 0) ? nil : "left over on Kavita: \(left.0) annotations, \(left.1) page bookmarks, \(left.2) book bookmarks"
        }
    }
}
