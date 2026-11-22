import CoreGraphics
import Core
import Foundation
@testable import OCR
import Testing

@Suite struct DetectionDecoderTests {
    func logit(_ probability: Double) -> Float { Float(log(probability / (1 - probability))) }

    @Test func keepsConfidentBoxesWithTheirClassAndClampsToThePage() {
        var logits = [Float](repeating: -10, count: 300 * 3)
        var boxes = [Float](repeating: 0, count: 300 * 4)
        // Query 0: text in a bubble, 0.9.  Query 1: bubble, 0.8, partly off the page.  Query 2: too weak.
        logits[0 * 3 + 1] = logit(0.9); boxes.replaceSubrange(0..<4, with: [0.5, 0.5, 0.2, 0.4])
        logits[1 * 3 + 0] = logit(0.8); boxes.replaceSubrange(4..<8, with: [0.95, 0.1, 0.2, 0.4])
        logits[2 * 3 + 2] = logit(0.2); boxes.replaceSubrange(8..<12, with: [0.3, 0.3, 0.1, 0.1])

        let detections = DetectionDecoder.decode(logits: logits, boxes: boxes, threshold: 0.35)
        #expect(detections.count == 2)
        let text = detections.first { $0.label == .textInBubble }!
        #expect(abs(text.score - 0.9) < 0.001)
        #expect(abs(text.box.x - 0.4) < 1e-6 && abs(text.box.y - 0.3) < 1e-6)
        #expect(abs(text.box.width - 0.2) < 1e-6 && abs(text.box.height - 0.4) < 1e-6)
        let bubble = detections.first { $0.label == .bubble }!
        #expect(abs(bubble.box.maxX - 1) < 1e-6, "clamped at the right edge")
        #expect(abs(bubble.box.y) < 1e-6, "clamped at the top")
    }

    @Test func duplicateBoxesOfTheSameClassCollapse() {
        let a = Detection(label: .freeText, score: 0.9, box: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let b = Detection(label: .freeText, score: 0.7, box: NormalizedRect(x: 0.11, y: 0.1, width: 0.2, height: 0.2))
        let other = Detection(label: .bubble, score: 0.8, box: a.box)
        #expect(DetectionDecoder.suppressOverlaps([b, a, other]) == [a, other])
    }
}

@Suite struct MangaOCRTextTests {
    let tokenizer = MangaOCRTokenizer(vocabulary: ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]", "<unused0>", "食", "べ", "る", "!", "1", "…", "・", "."])

    @Test func decodesCharactersAndSkipsSpecialTokens() {
        #expect(tokenizer.decode([2, 6, 7, 8, 3, 0, 5]) == "食べる")
        #expect(tokenizer.decode([99, 6]) == "食", "out-of-range ids are skipped")
    }

    @Test(arguments: [
        ("食 べ る", "食べる"),
        ("待って!", "待って！"),
        ("1000円", "１０００円"),
        ("えっ…", "えっ．．．"),
        ("あ・・・", "あ．．．"),
        ("中・点", "中・点"),
        ("ABC?", "ＡＢＣ？"),
    ])
    func postProcessingMatchesMangaOCR(raw: String, expected: String) {
        #expect(MangaOCRPostProcessor.process(raw) == expected)
    }
}

@Suite struct ReadingOrderTests {
    func box(_ x: Double, _ y: Double, _ w: Double = 0.1, _ h: Double = 0.2) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    @Test func rightToLeftThenTopToBottom() {
        // Two bands: [top-right, top-left], then [bottom-right, bottom-left].
        let items = [box(0.1, 0.6), box(0.7, 0.05), box(0.1, 0.1), box(0.7, 0.55)].map { ReadingOrder.Item(box: $0) }
        #expect(ReadingOrder.order(items) == [1, 2, 3, 0])
    }

    @Test func textsInOneBubbleStayTogether() {
        let bubbles = [box(0.5, 0.0, 0.4, 0.4)]
        // Two columns in the bubble on the right; a free text to its left at the same height.
        let right = box(0.75, 0.05), left = box(0.55, 0.1), outside = box(0.2, 0.05)
        let items = [outside, left, right].map { ReadingOrder.Item(box: $0, bubble: ReadingOrder.containingBubble(of: $0, in: bubbles)) }
        #expect(items.map(\.bubble) == [nil, 0, 0])
        #expect(ReadingOrder.order(items) == [2, 1, 0])
    }

    @Test func slightlyOffsetBlocksShareABand() {
        let items = [box(0.1, 0.12), box(0.6, 0.1)].map { ReadingOrder.Item(box: $0) }
        #expect(ReadingOrder.order(items) == [1, 0])
    }
}

@Suite struct TextLayoutTests {
    let column = CGRect(x: 0, y: 0, width: 10, height: 100)

    @Test func singleVerticalColumnMapsTopToBottom() {
        #expect(TextLayout.characterIndex(of: CGPoint(x: 5, y: 2), in: column, characterCount: 10, vertical: true) == 0)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 5, y: 55), in: column, characterCount: 10, vertical: true) == 5)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 5, y: 99), in: column, characterCount: 10, vertical: true) == 9)
    }

    @Test func verticalColumnsRunRightToLeft() {
        // 20 characters in two 10-character columns.
        let box = CGRect(x: 0, y: 0, width: 20, height: 100)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 15, y: 5), in: box, characterCount: 20, vertical: true) == 0)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 5, y: 5), in: box, characterCount: 20, vertical: true) == 10)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 5, y: 95), in: box, characterCount: 20, vertical: true) == 19)
    }

    @Test func horizontalRowsRunLeftToRightTopToBottom() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 20)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 5, y: 5), in: box, characterCount: 20, vertical: false) == 0)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 95, y: 5), in: box, characterCount: 20, vertical: false) == 9)
        #expect(TextLayout.characterIndex(of: CGPoint(x: 5, y: 15), in: box, characterCount: 20, vertical: false) == 10)
    }

    @Test func edgeCasesClamp() {
        #expect(TextLayout.characterIndex(of: .zero, in: column, characterCount: 1, vertical: true) == 0)
        #expect(TextLayout.characterIndex(of: CGPoint(x: -50, y: 500), in: column, characterCount: 10, vertical: true) == 9)
    }
}

@Suite struct OCRCacheTests {
    @Test func storesPerChapterPageAndModelVersion() throws {
        let database = try AppDatabase.inMemory()
        let cache = OCRCache(database: database, modelVersion: "v1")
        let page = OCRPage(imageWidth: 100, imageHeight: 200, blocks: [
            OCRBlock(box: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.3), text: "食べる", vertical: true, kind: .bubbleText),
        ])
        #expect(cache.page(chapterId: 1, page: 0) == nil)
        try cache.store(page, chapterId: 1, page: 0)
        #expect(cache.page(chapterId: 1, page: 0) == page)
        #expect(cache.page(chapterId: 1, page: 1) == nil)

        let newer = OCRCache(database: database, modelVersion: "v2")
        #expect(newer.page(chapterId: 1, page: 0) == nil, "another model version re-runs OCR")
        try newer.removeOtherVersions()
        #expect(try newer.count() == 0)
    }

    @Test func blockHitTesting() {
        let block = OCRBlock(box: NormalizedRect(x: 0.5, y: 0.1, width: 0.1, height: 0.3), text: "あ", vertical: true, kind: .bubbleText)
        let page = OCRPage(imageWidth: 1, imageHeight: 1, blocks: [block])
        #expect(page.block(at: CGPoint(x: 0.55, y: 0.2)) == block)
        #expect(page.block(at: CGPoint(x: 0.2, y: 0.2)) == nil)
    }
}

@Suite @MainActor struct OCRModelStoreTests {
    @Test func manifestMatchesTheFetchScript() throws {
        // The dev script and the in-app download must pin the same revision.
        let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../scripts/fetch-ocr-models.sh").standardized
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("REVISION=\(OCRModelStore.revision)"))
        for file in OCRModelStore.files { #expect(text.contains(file.path)) }
        #expect(OCRModelStore.totalBytes > 120_000_000 && OCRModelStore.totalBytes < 140_000_000)
    }

    @Test func startsNotInstalledAndDetectsAnInstall() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ocr-store-\(UUID().uuidString)")
        #expect(OCRModelStore(directory: directory).state == .notInstalled)
        let compiled = directory.appending(path: "compiled")
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data().write(to: compiled.appending(path: "vocab.txt"))
        for package in OCRModelStore.packages {
            try FileManager.default.createDirectory(at: compiled.appending(path: "\(package).mlmodelc"), withIntermediateDirectories: true)
        }
        let store = OCRModelStore(directory: directory)
        #expect(store.state == .installed)
        #expect(store.modelDirectory?.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == compiled.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        store.delete()
        #expect(store.state == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: directory.path()))
    }

    @Test func hashesFilesInChunks() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        #expect(try OCRModelStore.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

import CoreML

@Suite struct MultiArrayReadingTests {
    @Test func paddedRowsAreReadThroughStrides() throws {
        // A [1, 2, 3] float32 array whose rows are padded to 4 elements.
        var storage: [Float] = [1, 2, 3, -9, 4, 5, 6, -9]
        let array = try storage.withUnsafeMutableBytes { bytes in
            try MLMultiArray(dataPointer: bytes.baseAddress!, shape: [1, 2, 3], dataType: .float32, strides: [8, 4, 1])
        }
        #expect(array.floats() == [1, 2, 3, 4, 5, 6])
    }
}

@Suite struct TextOrientationTests {
    @Test(arguments: [
        // Multi-column vertical block about as wide as tall.
        (CGSize(width: 199, height: 168), "僕の兄ちゃんさ．．．昔から体が弱くて", true),
        (CGSize(width: 60, height: 300), "外で遊べなかったんだ", true),
        // One wide line.
        (CGSize(width: 300, height: 60), "営業中", false),
        // English lettering in a square bubble.
        (CGSize(width: 231, height: 225), "ＮＥＶＥＲＧＩＶＥＵＰ．", false),
        // Mostly Japanese with a number.
        (CGSize(width: 120, height: 120), "家賃は５万だ", true),
    ])
    func orientation(size: CGSize, text: String, vertical: Bool) {
        #expect(TextOrientation.isVertical(pixelSize: size, text: text) == vertical)
    }
}

/// A block's real lines, measured from its picture, place a tap on the right character.
@Suite struct TextLinesTests {
    /// Black cells on white: `columns` are the vertical lines right to left, each a count of
    /// characters; `furigana` adds a thin strip beside the first one. Cells are 20 px with a 4 px
    /// gap, columns 12 px apart.
    static func block(columns: [Int], furigana: Bool = false, inverted: Bool = false) -> (gray: [UInt8], width: Int, height: Int) {
        let cell = 20, gap = 4, between = 12, margin = 10
        let width = margin * 2 + columns.count * cell + (columns.count - 1) * between + (furigana ? 10 : 0)
        let height = margin * 2 + (columns.max() ?? 1) * (cell + gap)
        var gray = [UInt8](repeating: inverted ? 0 : 255, count: width * height)
        let ink: UInt8 = inverted ? 255 : 0
        for (index, count) in columns.enumerated() {
            // The first column is the rightmost.
            let x = width - margin - (furigana ? 10 : 0) - (index + 1) * cell - index * between
            for character in 0..<count {
                let y = margin + character * (cell + gap)
                for row in y..<(y + cell) { for column in x..<(x + cell) { gray[row * width + column] = ink } }
            }
        }
        if furigana {
            let x = width - margin - 6
            for row in (margin + 4)..<(margin + 40) { for column in x..<(x + 5) { gray[row * width + column] = ink } }
        }
        return (gray, width, height)
    }

    @Test func findsColumnsOfDifferentLengths() {
        let picture = Self.block(columns: [5, 5, 2])
        let lines = TextLines.lines(gray: picture.gray, width: picture.width, height: picture.height, vertical: true)
        #expect(lines.count == 3)
        #expect(lines[0].midX > lines[1].midX && lines[1].midX > lines[2].midX, "right to left")
        #expect(lines[2].height < lines[0].height * 0.5, "the last column is short")
    }

    @Test func furiganaIsNotALineAndWhiteOnBlackWorks() {
        let withFurigana = Self.block(columns: [4, 3], furigana: true)
        #expect(TextLines.lines(gray: withFurigana.gray, width: withFurigana.width, height: withFurigana.height, vertical: true).count == 2)
        let inverted = Self.block(columns: [4, 4, 4], inverted: true)
        #expect(TextLines.lines(gray: inverted.gray, width: inverted.width, height: inverted.height, vertical: true).count == 3)
    }

    /// The case the even spread gets wrong: 12 characters as 5 + 5 + 2.
    @Test func aTapLandsOnItsCharacter() {
        let picture = Self.block(columns: [5, 5, 2])
        let lines = TextLines.lines(gray: picture.gray, width: picture.width, height: picture.height, vertical: true)
        let box = CGRect(x: 0, y: 0, width: picture.width, height: picture.height)
        /// The middle of character `row` in column `column` (0 = rightmost).
        func tap(_ column: Int, _ row: Int) -> CGPoint {
            CGPoint(x: Double(picture.width - 10 - column * 32 - 10), y: Double(10 + row * 24 + 10))
        }
        var measured = 0, even = 0
        let cells = [(0, 5), (1, 5), (2, 2)].flatMap { column, count in (0..<count).map { (column, $0) } }
        for (expected, cell) in cells.enumerated() {
            let point = tap(cell.0, cell.1)
            if TextLayout.characterIndex(of: point, in: box, characterCount: 12, vertical: true, lines: lines) == expected { measured += 1 }
            if TextLayout.characterIndex(of: point, in: box, characterCount: 12, vertical: true) == expected { even += 1 }
        }
        #expect(measured == 12, "every character, with the measured lines")
        #expect(even < 12, "the even spread misses some (\(even) of 12), which is what was reported")
    }

    /// Each character gets the box its glyph is in: cut at the gaps, not just evenly.
    @Test func cellsSitOnTheGlyphs() {
        let picture = Self.block(columns: [5, 5, 2])
        let lines = TextLines.lines(gray: picture.gray, width: picture.width, height: picture.height, vertical: true)
        let cells = TextLines.cells(gray: picture.gray, width: picture.width, height: picture.height, vertical: true, lines: lines, count: 12)
        #expect(cells.count == 12)
        let all = [(0, 5), (1, 5), (2, 2)].flatMap { column, count in (0..<count).map { (column, $0) } }
        for (index, place) in all.enumerated() where index < cells.count {
            // The drawn glyph: 20 px square, columns 32 px apart from the right, rows 24 px apart.
            let glyph = CGRect(x: Double(picture.width - 10 - place.0 * 32 - 20), y: Double(10 + place.1 * 24), width: 20, height: 20)
            let cell = CGRect(x: cells[index].minX * Double(picture.width), y: cells[index].minY * Double(picture.height),
                              width: cells[index].width * Double(picture.width), height: cells[index].height * Double(picture.height))
            #expect(cell.insetBy(dx: -1.5, dy: -1.5).contains(glyph), "character \(index): \(cell) holds \(glyph)")
            #expect(cell.height <= 25, "and no more than the gap to the next (\(cell.height))")
            #expect(TextLayout.characterIndex(of: CGPoint(x: glyph.midX, y: glyph.midY),
                                              in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height), cells: cells) == index)
        }
    }

    /// Characters of different widths in a row (a title: 第1夜:…): each place is its glyph's.
    @Test func narrowAndSplitGlyphsKeepTheirOwnPlaces() {
        // Widths of the glyphs, and a 3 px gap; the fourth character is in two parts (い).
        let glyphs: [[Int]] = [[20], [5], [20], [7, 7], [20], [20]]
        let height = 30
        var x = 6
        var spans: [ClosedRange<Int>] = []
        var parts: [ClosedRange<Int>] = []
        for glyph in glyphs {
            let from = x
            for (index, part) in glyph.enumerated() {
                parts.append(x...(x + part - 1))
                x += part + (index < glyph.count - 1 ? 4 : 0)
            }
            spans.append(from...(x - 1))
            x += 3
        }
        let width = x + 3
        var gray = [UInt8](repeating: 255, count: width * height)
        for part in parts { for row in 6..<24 { for column in part { gray[row * width + column] = 0 } } }
        let lines = TextLines.lines(gray: gray, width: width, height: height, vertical: false)
        #expect(lines.count == 1)
        let cells = TextLines.cells(gray: gray, width: width, height: height, vertical: false, lines: lines, count: glyphs.count)
        #expect(cells.count == glyphs.count)
        for (index, span) in spans.enumerated() where index < cells.count {
            let from = cells[index].minX * Double(width), to = cells[index].maxX * Double(width)
            #expect(from <= Double(span.lowerBound) && to >= Double(span.upperBound + 1), "character \(index): \(from)…\(to) holds \(span)")
            #expect(to - from <= Double(span.count) + 4, "and little else (\(to - from) for \(span.count))")
        }
    }

    /// Bold glyphs that touch: the cut goes where the ink is thinnest between them.
    @Test func touchingGlyphsAreCutAtTheThinnestPlace() {
        // Three 20 px glyphs; the first two joined by a 2 px bridge at x = 28…29 (thin: 2 rows).
        let width = 80, height = 30
        var gray = [UInt8](repeating: 255, count: width * height)
        for (from, to) in [(6, 27), (30, 49), (54, 73)] { for row in 6..<24 { for column in from...to { gray[row * width + column] = 0 } } }
        for row in 14..<16 { for column in 28...29 { gray[row * width + column] = 0 } }
        let lines = TextLines.lines(gray: gray, width: width, height: height, vertical: false)
        let cells = TextLines.cells(gray: gray, width: width, height: height, vertical: false, lines: lines, count: 3)
        #expect(cells.count == 3)
        guard cells.count == 3 else { return }
        let cut = cells[0].maxX * Double(width)
        #expect(cut >= 28 && cut <= 30, "between the first two glyphs (\(cut))")
        #expect(abs(cells[1].maxX * Double(width) - 52) <= 1.5, "and in the gap before the third")
    }

    @Test func estimatedPlacesWhenNothingWasMeasured() {
        // No lines: the even spread, right to left.
        let even = TextLayout.characterRects(characterCount: 4, vertical: true, lines: [], boxSize: CGSize(width: 100, height: 100))
        #expect(even.count == 4)
        #expect(even[0].midX > even[2].midX && even[0].midY < even[1].midY)
        // Lines only: along them by length.
        let lines = [CGRect(x: 0.6, y: 0, width: 0.3, height: 1), CGRect(x: 0.1, y: 0, width: 0.3, height: 0.5)]
        let rects = TextLayout.characterRects(characterCount: 6, vertical: true, lines: lines, boxSize: CGSize(width: 100, height: 100))
        #expect(rects.count == 6)
        #expect(rects[3].minX == 0.6 && rects[4].minX == 0.1)
        // A tap outside every cell goes to the nearest.
        #expect(TextLayout.characterIndex(of: CGPoint(x: 50, y: 99), in: CGRect(x: 0, y: 0, width: 100, height: 100), cells: rects) == 5
                || TextLayout.characterIndex(of: CGPoint(x: 50, y: 99), in: CGRect(x: 0, y: 0, width: 100, height: 100), cells: rects) == 3)
    }

    @Test func charactersAreSharedByLength() {
        #expect(TextLayout.characterCounts([100, 100, 40], total: 12) == [5, 5, 2])
        #expect(TextLayout.characterCounts([100, 10], total: 5) == [4, 1], "a line always has one")
        #expect(TextLayout.characterCounts([50, 50], total: 7).reduce(0, +) == 7)
    }

    /// Lettering is set one character to a square, but not everything read is: the … drawn in
    /// one square is read as three dots, and ⁉ as two marks. The text is matched to the squares.
    @Test func dotsAndPairedMarksShareTheirSquares() {
        let width = 48 + 48, height = 6 * 51 + 48
        let context = SyntheticPage.context(width: width, height: height)
        SyntheticPage.draw("本当に何…⁉", in: context, at: CGPoint(x: 24, y: 24), vertical: true, height: height)
        let layout = TextLines.layout(of: NormalizedRect(x: 0, y: 0, width: 1, height: 1), in: context.makeImage()!, vertical: true, text: "本当に何．．．！？")
        #expect(layout.exact)
        #expect(layout.cells.count == 9)
        guard layout.cells.count == 9 else { return }
        // The first four in their own squares, the dots sharing the fifth, the marks side by
        // side in the sixth.
        let fifth = CGFloat(24 + 4 * 50) / CGFloat(height), sixth = CGFloat(24 + 5 * 50) / CGFloat(height)
        #expect(layout.cells[3].maxY <= fifth + 0.02)
        for dot in 4...6 { #expect(layout.cells[dot].minY >= fifth - 0.02 && layout.cells[dot].maxY <= sixth + 0.02) }
        #expect(layout.cells[7].minY >= layout.cells[6].maxY - 0.01 && layout.cells[7].maxX <= layout.cells[8].minX + 0.001)
    }

    /// A bubble's outline through the block's corners, the screen tone beyond it and a stray
    /// mark beside the lettering are not lettering: the characters are still all found.
    @Test func outlineToneAndStrayMarksAreLeftOut() {
        let columns = ["今日はいい天", "気ですね。"]
        let width = 2 * 48 + 26 + 120, height = 6 * 51 + 100
        let context = SyntheticPage.context(width: width, height: height)
        for (index, text) in columns.enumerated() {
            SyntheticPage.draw(text, in: context, at: CGPoint(x: Double(width - 60 - 48 - index * 74), y: 50), vertical: true, height: height)
        }
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(4)
        // The outline cuts the corners off; past it, dots of tone.
        context.strokeEllipse(in: CGRect(x: -20, y: -20, width: width + 40, height: height + 40))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for dot in 0..<4 { context.fillEllipse(in: CGRect(x: 3 + dot % 2 * 9, y: 3 + dot / 2 * 9, width: 4, height: 4)) }
        // A sweat drop beside the lettering.
        context.fillEllipse(in: CGRect(x: 34, y: height / 2, width: 9, height: 14))
        let layout = TextLines.layout(of: NormalizedRect(x: 0, y: 0, width: 1, height: 1), in: context.makeImage()!, vertical: true, text: columns.joined())
        #expect(layout.exact)
        #expect(layout.lines.count == 2, "two lines (found \(layout.lines.count))")
        #expect(layout.cells.count == 11)
    }

    /// Text that doesn't match what's drawn (a character missed in reading) is placed as well
    /// as can be, but not called exact: nothing will be drawn on the page for it.
    @Test func misreadTextIsNotExact() {
        let width = 96, height = 5 * 51 + 48
        let context = SyntheticPage.context(width: width, height: height)
        SyntheticPage.draw("食べたいな", in: context, at: CGPoint(x: 24, y: 24), vertical: true, height: height)
        let layout = TextLines.layout(of: NormalizedRect(x: 0, y: 0, width: 1, height: 1), in: context.makeImage()!, vertical: true, text: "食べたい")
        #expect(!layout.exact)
        #expect(layout.cells.count == 4)
    }

    /// Real glyphs (Hiragino, drawn as manga columns): columns of 6, 5 and 2 characters, with
    /// characters that have gaps inside them (い, 川) and small punctuation.
    @Test func realLetteringInThreeColumns() {
        let columns = ["今日はいい天", "気ですね。", "川い"]
        let width = 3 * 48 + 2 * 26 + 48, height = 6 * 51 + 48
        let context = SyntheticPage.context(width: width, height: height)
        for (index, text) in columns.enumerated() {
            SyntheticPage.draw(text, in: context, at: CGPoint(x: Double(width - 24 - 48 - index * 74), y: 24), vertical: true, height: height)
        }
        let image = context.makeImage()!
        let lines = TextLines.lines(of: NormalizedRect(x: 0, y: 0, width: 1, height: 1), in: image, vertical: true)
        #expect(lines.count == 3, "three columns (found \(lines.count))")
        guard lines.count == 3 else { return }
        let counts = TextLayout.characterCounts(lines.map(\.height), total: 13)
        #expect(counts == [6, 5, 2], "characters per column from their lengths (\(counts))")
        // A tap in the middle of each character finds it.
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        var right = 0
        var expected = 0
        for (index, text) in columns.enumerated() {
            for row in 0..<text.count {
                let point = CGPoint(x: Double(width - 24 - 24 - index * 74), y: 24 + Double(row) * 48 * 1.05 + 24)
                if TextLayout.characterIndex(of: point, in: box, characterCount: 13, vertical: true, lines: lines) == expected { right += 1 }
                expected += 1
            }
        }
        #expect(right >= 12, "\(right) of 13 taps land on their character")
        // And the measured places of real glyphs: every tap in the middle of a character.
        let layout = TextLines.layout(of: NormalizedRect(x: 0, y: 0, width: 1, height: 1), in: image, vertical: true, text: columns.joined())
        #expect(layout.cells.count == 13)
        #expect(layout.exact, "found on the grid")
        var exact = 0
        expected = 0
        for (index, text) in columns.enumerated() {
            for row in 0..<text.count {
                let point = CGPoint(x: Double(width - 24 - 24 - index * 74), y: 24 + Double(row) * 48 * 1.05 + 24)
                if TextLayout.characterIndex(of: point, in: box, cells: layout.cells) == expected { exact += 1 }
                expected += 1
            }
        }
        #expect(exact == 13, "\(exact) of 13 taps land with the measured places")
    }
}
