import Foundation

/// How many characters of text each section holds, for Hoshi-style progress
/// ("12% · 410 / 82,515"). Counted as Hoshi Reader and ッツ count (`count(html:)`), and as
/// BookReader.js counts on the page. Cached next to the unpacked book.
public struct BookTextIndex: Codable, Equatable, Sendable {
    /// Characters per spine item.
    public var sections: [Int]

    public var total: Int { sections.reduce(0, +) }

    /// Characters before section `index`.
    public func start(of index: Int) -> Int {
        sections.prefix(max(0, min(index, sections.count))).reduce(0, +)
    }

    static let filename = ".characters-v3.json"

    /// Characters read when Kavita says `pagesRead` of `pages`: everything before the
    /// section being read (the position inside it isn't known here), or all of it once read.
    public func charactersRead(pagesRead: Int, pages: Int) -> Int {
        pages > 0 && pagesRead >= pages ? total : start(of: pagesRead)
    }

    static func load(folder: URL, package: EpubPackage) -> BookTextIndex {
        let cache = folder.appending(path: filename)
        if let data = try? Data(contentsOf: cache), let index = try? JSONDecoder().decode(BookTextIndex.self, from: data),
           index.sections.count == package.spine.count {
            return index
        }
        let index = BookTextIndex(sections: package.spine.map { item in
            (try? String(contentsOf: folder.appending(path: item.path), encoding: .utf8)).map { count(html: $0) } ?? 0
        })
        try? JSONEncoder().encode(index).write(to: cache)
        return index
    }

    /// The characters of an (X)HTML document that count: letters only (kana, kanji, ー, 々,
    /// Latin, full-width and Korean letters and digits), without furigana, punctuation, spaces
    /// or markup. Hoshi Reader's and ッツ's rule; BookReader.js counts with the same class.
    public static func count(html: String) -> Int {
        var text = html
        if let body = text.range(of: "<body\\b[\\s\\S]*?</body>", options: [.regularExpression, .caseInsensitive]) {
            text = String(text[body])
        }
        for element in ["script", "style", "rt", "rp"] {
            text = text.replacingOccurrences(of: "<\(element)\\b[^>]*>[\\s\\S]*?</\(element)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&[#a-zA-Z0-9]+;", with: "", options: .regularExpression)
        return text.unicodeScalars.count { counted.contains($0) }
    }

    /// Hoshi's and ッツ's class: `[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ가-힣ㄱ-ㆎ\p{Radical}\p{Unified_Ideograph}]`.
    static let counted: CharacterSet = {
        var set = CharacterSet(charactersIn: "0"..."9")
        for range: ClosedRange<Unicode.Scalar> in ["A"..."Z", "a"..."z", "々"..."〇", "ぁ"..."ゖ", "ゝ"..."ゞ", "ァ"..."ヺ",
                                                  "０"..."９", "Ａ"..."Ｚ", "ａ"..."ｚ", "ｦ"..."ﾝ", "가"..."힣", "ㄱ"..."ㆎ"] {
            set.insert(charactersIn: range)
        }
        set.insert(charactersIn: "○◯〻ー")
        // Radical: the CJK radicals blocks; Unified_Ideograph: the CJK ideograph blocks.
        for range: ClosedRange<Unicode.Scalar> in ["\u{2E80}"..."\u{2E99}", "\u{2E9B}"..."\u{2EF3}", "\u{2F00}"..."\u{2FD5}",
                                                  "\u{3400}"..."\u{4DBF}", "\u{4E00}"..."\u{9FFF}", "\u{20000}"..."\u{3FFFF}"] {
            set.insert(charactersIn: range)
        }
        // The compatibility block's unified ideographs (the rest are compatibility forms).
        set.insert(charactersIn: "\u{FA0E}\u{FA0F}\u{FA11}\u{FA13}\u{FA14}\u{FA1F}\u{FA21}\u{FA23}\u{FA24}\u{FA27}\u{FA28}\u{FA29}")
        return set
    }()
}
