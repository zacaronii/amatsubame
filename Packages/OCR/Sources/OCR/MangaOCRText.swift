import Foundation

/// manga-ocr's character vocabulary (BertJapaneseTokenizer, one character per token).
public struct MangaOCRTokenizer: Sendable {
    public static let startToken: Int32 = 2  // [CLS]
    public static let endToken: Int32 = 3    // [SEP]

    let vocabulary: [String]

    public init(vocabulary: [String]) {
        self.vocabulary = vocabulary
    }

    public init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        self.init(vocabulary: text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) })
    }

    /// Decodes token ids, skipping special and unused tokens, then applies manga-ocr's clean-up.
    public func decode(_ ids: [Int32]) -> String {
        let pieces = ids.compactMap { id -> String? in
            guard id >= 5, Int(id) < vocabulary.count else { return nil }
            let token = vocabulary[Int(id)]
            return token.hasPrefix("<unused") || token.hasPrefix("[") && token.hasSuffix("]") && token.count > 1 ? nil : token
        }
        return MangaOCRPostProcessor.process(pieces.joined())
    }
}

/// manga-ocr's `post_process`: drop whitespace, normalize ellipses and dot runs,
/// and convert ASCII letters, digits and symbols to full-width (jaconv `h2z`).
public enum MangaOCRPostProcessor {
    public static func process(_ text: String) -> String {
        var result = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        result = result.replacingOccurrences(of: "…", with: "...")
        result = collapseDots(result)
        return String(String.UnicodeScalarView(result.unicodeScalars.map { scalar in
            (0x21...0x7E).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0xFEE0)! : scalar
        }))
    }

    /// Any run of two or more `・`/`.` becomes the same number of `.`.
    private static func collapseDots(_ text: String) -> String {
        var output = ""
        var run = ""
        func flush() {
            output += run.count >= 2 ? String(repeating: ".", count: run.count) : run
            run = ""
        }
        for character in text {
            if character == "・" || character == "." {
                run.append(character)
            } else {
                flush()
                output.append(character)
            }
        }
        flush()
        return output
    }
}
