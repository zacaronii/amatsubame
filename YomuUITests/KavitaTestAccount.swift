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

    /// A series' id, found by its name.
    func seriesId(named name: String) throws -> Int {
        let found = try XCTUnwrap(try call("GET", "api/Search/search", query: ["queryString": name]) as? [String: Any], "the search")
        let series = try list(found["series"], "the search's series").first { $0["name"] as? String == name }
        return try XCTUnwrap(series?["seriesId"] as? Int, "the series")
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
    func snapshot(bookSeries: String? = nil) throws -> Snapshot {
        Snapshot(account: self, bookSeries: bookSeries, annotations: Set(try annotations().compactMap { $0["id"] as? Int }),
                 pageBookmarks: Set(try pageBookmarks().compactMap { $0["id"] as? Int }),
                 bookBookmarks: Set(try bookSeries.map { try bookBookmarks(series: $0) } ?? []),
                 wantToRead: try wantToRead())
    }

    struct Snapshot {
        let account: KavitaTestAccount
        let bookSeries: String?
        let annotations: Set<Int>
        let pageBookmarks: Set<Int>
        let bookBookmarks: Set<BookBookmark>
        let wantToRead: Set<Int>

        /// Removes the marks made since the snapshot. Returns what's still left over.
        @discardableResult
        func restore() throws -> String? {
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
            let left = (try account.annotations().count - annotations.count, try account.pageBookmarks().count - pageBookmarks.count,
                        try bookSeries.map { try account.bookBookmarks(series: $0).count - bookBookmarks.count } ?? 0)
            return left == (0, 0, 0) ? nil : "left over on Kavita: \(left.0) annotations, \(left.1) page bookmarks, \(left.2) book bookmarks"
        }
    }
}
