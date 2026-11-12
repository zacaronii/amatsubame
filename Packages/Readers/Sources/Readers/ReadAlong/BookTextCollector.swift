import Foundation
import WebKit

/// Reads a book's text the way the reader shows it: each section is loaded once in a hidden
/// web view with the reader's own scripts, and its runs (`BookReader.js` `wordRuns()`) are
/// kept. Read-along positions then mean the same thing in the reader. Saved in the book's folder.
@MainActor
public enum BookTextCollector {
    static let cacheName = ".read-along-runs-v1.json"

    public static func runs(chapterId: Int, repository: BookRepository, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> [BookTextRun] {
        let book = try await repository.book(chapterId: chapterId)
        let cache = book.folder.appending(path: cacheName)
        if let data = try? Data(contentsOf: cache), let runs = try? JSONDecoder().decode([BookTextRun].self, from: data) {
            return runs
        }
        let controller = BookWebController(folder: book.folder)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 1200)
        var runs: [BookTextRun] = []
        for (section, item) in book.package.spine.enumerated() {
            progress(Double(section) / Double(max(book.package.spine.count, 1)))
            guard let url = BookSchemeHandler.url(chapterId: chapterId, path: item.path), await controller.loadAndWait(url) else { continue }
            let texts = await controller.evaluate("window.bookReader ? window.bookReader.wordRuns() : []") as? [String] ?? []
            for (run, text) in texts.enumerated() where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runs.append(BookTextRun(section: section, run: run, text: text))
            }
        }
        progress(1)
        if let data = try? JSONEncoder().encode(runs) { try? data.write(to: cache, options: .atomic) }
        return runs
    }
}
