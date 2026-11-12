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
