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
        nonisolated(unsafe) var result: Result<Any?, any Error> = .success(nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(error); return }
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                result = .failure(URLError(.badServerResponse))
                return
            }
            result = .success(data.flatMap { $0.isEmpty ? nil : try? JSONSerialization.jsonObject(with: $0) })
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return try result.get()
    }

    func annotations() throws -> [[String: Any]] {
        try call("POST", "api/Annotation/all-filtered", query: ["pageNumber": "1", "pageSize": "100"], body: "{}") as? [[String: Any]] ?? []
    }

    func pageBookmarks() throws -> [[String: Any]] {
        try call("POST", "api/Reader/all-bookmarks", body: #"{"statements":[],"combination":1,"limitTo":0}"#) as? [[String: Any]] ?? []
    }

    /// A series' chapters, found by its name.
    func chapters(series name: String) throws -> [Int] {
        let found = try call("GET", "api/Search/search", query: ["queryString": name]) as? [String: Any]
        let series = (found?["series"] as? [[String: Any]])?.first { $0["name"] as? String == name }
        guard let id = series?["seriesId"] as? Int else { return [] }
        let volumes = try call("GET", "api/Series/volumes", query: ["seriesId": String(id)]) as? [[String: Any]] ?? []
        return volumes.flatMap { ($0["chapters"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } }
    }

    /// A series' book bookmarks (Kavita's personal table of contents), as chapter, page and title.
    func bookBookmarks(series name: String) throws -> [BookBookmark] {
        try chapters(series: name).flatMap { chapter in
            (try call("GET", "api/Reader/ptoc", query: ["chapterId": String(chapter)]) as? [[String: Any]] ?? []).compactMap { entry in
                guard let page = entry["pageNumber"] as? Int, let title = entry["title"] as? String else { return nil }
                return BookBookmark(chapter: chapter, page: page, title: title)
            }
        }
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
                 bookBookmarks: Set(try bookSeries.map { try bookBookmarks(series: $0) } ?? []))
    }

    struct Snapshot {
        let account: KavitaTestAccount
        let bookSeries: String?
        let annotations: Set<Int>
        let pageBookmarks: Set<Int>
        let bookBookmarks: Set<BookBookmark>

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
            let left = (try account.annotations().count - annotations.count, try account.pageBookmarks().count - pageBookmarks.count,
                        try bookSeries.map { try account.bookBookmarks(series: $0).count - bookBookmarks.count } ?? 0)
            return left == (0, 0, 0) ? nil : "left over on Kavita: \(left.0) annotations, \(left.1) page bookmarks, \(left.2) book bookmarks"
        }
    }
}
