import CoreGraphics
import CoreML
import CoreText
import Foundation
import ImageIO
@testable import OCR
import UniformTypeIdentifiers
import Testing

/// Runs the real models when `OCR_MODELS_DIR` points at `scripts/fetch-ocr-models.sh`'s output.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OCR_MODELS_DIR"] != nil))
struct OCRModelTests {
    /// Compiles the fetched model packages once into a temporary folder.
    static let compiled: URL = {
        let source = URL(filePath: ProcessInfo.processInfo.environment["OCR_MODELS_DIR"]!)
        let output = FileManager.default.temporaryDirectory.appending(path: "ocr-compiled-\(OCRModelStore.revision.prefix(7))")
        let manager = FileManager.default
        try? manager.createDirectory(at: output, withIntermediateDirectories: true)
        for package in OCRModelStore.packages where !manager.fileExists(atPath: output.appending(path: "\(package).mlmodelc").path()) {
            let compiled = try! MLModel.compileModel(at: source.appending(path: "\(package).mlpackage"))
            try! manager.moveItem(at: compiled, to: output.appending(path: "\(package).mlmodelc"))
        }
        if !manager.fileExists(atPath: output.appending(path: "vocab.txt").path()) {
            try! manager.copyItem(at: source.appending(path: "vocab.txt"), to: output.appending(path: "vocab.txt"))
        }
        return output
    }()

    static func pipeline() throws -> OCRPipeline {
        try OCRPipeline(modelDirectory: compiled)
    }

    @Test(arguments: [("食べさせられなかった", true), ("今日はいい天気ですね", false), ("本当に？", true)])
    func recognizesRenderedText(text: String, vertical: Bool) async throws {
        let image = SyntheticPage.text(text, vertical: vertical)
        let block = try await Self.pipeline().recognize(region: NormalizedRect(x: 0, y: 0, width: 1, height: 1), in: image)
        #expect(block.text == text)
        #expect(block.vertical == vertical)
    }

    /// A real page (Pepper&Carrot, CC BY 4.0): both bubbles are found and read. In the iOS
    /// Simulator the detector's outputs once came back laid out differently from their strides,
    /// and this page got one bubble or none; run it there too
    /// (`xcodebuild test -scheme OCR` with `TEST_RUNNER_OCR_MODELS_DIR`).
    @Test func readsBothBubblesOnARealPage() async throws {
        let url = try #require(Bundle.module.url(forResource: "pepper-carrot-e01p02", withExtension: "jpg", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (page, _) = try await Self.pipeline().recognize(page: image)
        let texts = page.blocks.filter { $0.kind == .bubbleText }.map(\.text)
        #expect(texts.count == 2, "\(texts)")
        #expect(texts.contains { $0.contains("カンペキ") })
        #expect(texts.contains { $0.contains("そんなこと") })
    }

    @Test func detectsAndReadsSpeechBubblesInReadingOrder() async throws {
        let (page, timings) = try await Self.pipeline().recognize(page: SyntheticPage.twoBubbles())
        print("Detected \(page.blocks.map(\.text)) — detection \(timings.detection), recognition \(timings.recognition)")
        #expect(page.blocks.count == 2)
        #expect(page.blocks.first?.text == "おはよう", "right-hand bubble is read first")
        #expect(page.blocks.last?.text == "食べたい")
        #expect(page.blocks.allSatisfy { $0.vertical })
    }
}

/// Manga-like test images drawn with CoreText: black Mincho text on white.
enum SyntheticPage {
    static var font: CTFont { CTFontCreateWithName("Hiragino Mincho ProN W6" as CFString, 48, nil) }

    static func context(width: Int, height: Int) -> CGContext {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Draws upright characters one by one: down a column (vertical, like manga) or along a line.
    /// Origin is top-left in `at`. (CoreText's vertical-forms attribute would rotate each glyph.)
    static func draw(_ text: String, in context: CGContext, at origin: CGPoint, vertical: Bool, height: Int) {
        let size: CGFloat = 48
        for (index, character) in text.enumerated() {
            let attributed = NSAttributedString(string: String(character), attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let x = vertical ? origin.x : origin.x + CGFloat(index) * size
            let y = vertical ? origin.y + CGFloat(index) * size * 1.05 : origin.y
            // CoreGraphics' origin is bottom-left; baseline sits ~0.85em below the cell top.
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - y - size * 0.88)
            CTLineDraw(line, context)
        }
    }

    static func text(_ text: String, vertical: Bool) -> CGImage {
        let count = text.count
        let width = vertical ? 96 : count * 48 + 48
        let height = vertical ? count * 51 + 48 : 96
        let context = context(width: width, height: height)
        draw(text, in: context, at: CGPoint(x: 24, y: 24), vertical: vertical, height: height)
        return context.makeImage()!
    }

    /// A gray page with two white bubbles of vertical text, side by side.
    static func twoBubbles() -> CGImage {
        let width = 900, height = 1280
        let context = context(width: width, height: height)
        context.setFillColor(CGColor(gray: 0.82, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (text, centerX) in [("おはよう", 640.0), ("食べたい", 260.0)] {
            let bubble = CGRect(x: centerX - 110, y: CGFloat(height) - 640, width: 220, height: 400)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: bubble)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(4)
            context.strokeEllipse(in: bubble)
            draw(text, in: context, at: CGPoint(x: centerX - 24, y: 340), vertical: true, height: height)
        }
        return context.makeImage()!
    }
}


/// Runs OCR on real pages in `OCR_PAGES_DIR` (not committed) and writes each page with
/// numbered boxes next to it, for checking text and reading order by eye.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OCR_MODELS_DIR"] != nil
    && ProcessInfo.processInfo.environment["OCR_PAGES_DIR"] != nil))
struct RealPageOCR {
    @Test func reportPages() async throws {
        let directory = URL(filePath: ProcessInfo.processInfo.environment["OCR_PAGES_DIR"]!)
        let pipeline = try OCRModelTests.pipeline()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["webp", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("annotated-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let (page, timings) = try await pipeline.recognize(page: image)
            print("== \(file.lastPathComponent) \(image.width)x\(image.height): \(page.blocks.count) blocks, detect \(timings.detection), read \(timings.recognition)")
            for (index, block) in page.blocks.enumerated() {
                print(String(format: "  %2d %@ %.2f [%.2f %.2f %.2f %.2f] %@", index + 1, block.vertical ? "V" : "H", block.score,
                             block.box.x, block.box.y, block.box.width, block.box.height, block.text))
            }
            try Annotation.write(image, page: page, to: directory.appending(path: "annotated-\(file.deletingPathExtension().lastPathComponent).png"))
        }
    }
}

enum Annotation {
    static func write(_ image: CGImage, page: OCRPage, to url: URL) throws {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        for (index, block) in page.blocks.enumerated() {
            var rect = block.box.pixels(in: size)
            rect.origin.y = size.height - rect.maxY
            context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
            context.setLineWidth(3)
            context.stroke(rect)
            let label = NSAttributedString(string: "\(index + 1)", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil),
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: rect.minX + 4, y: rect.maxY - 34)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }
}
