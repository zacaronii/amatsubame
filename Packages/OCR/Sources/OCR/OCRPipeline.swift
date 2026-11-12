import CoreGraphics
import CoreML
import Foundation

/// Which processors run each model. Measured on an M-series Mac (2026-10-31):
/// the Neural Engine compiler rejects the detector (and `.all` then fails to load),
/// and `.all` crashes with the decoder; the encoder runs anywhere.
public struct OCRComputeUnits: Sendable {
    public var detector: MLComputeUnits
    public var encoder: MLComputeUnits
    public var decoder: MLComputeUnits

    public init(detector: MLComputeUnits, encoder: MLComputeUnits, decoder: MLComputeUnits) {
        self.detector = detector
        self.encoder = encoder
        self.decoder = decoder
    }

    public static var `default`: OCRComputeUnits {
        #if targetEnvironment(simulator)
        OCRComputeUnits(detector: .cpuOnly, encoder: .cpuOnly, decoder: .cpuOnly)
        #else
        OCRComputeUnits(detector: .cpuAndGPU, encoder: .cpuAndNeuralEngine, decoder: .cpuOnly)
        #endif
    }
}

/// Detects text blocks on a page and reads them with manga-ocr.
public actor OCRPipeline {
    public static let detectionThreshold = 0.35

    private let detector: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let tokenizer: MangaOCRTokenizer
    private let threshold: Double

    /// Loads the compiled models from `OCRModelStore.modelDirectory`.
    public init(modelDirectory: URL, computeUnits: OCRComputeUnits = .default, threshold: Double = OCRPipeline.detectionThreshold) throws {
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: modelDirectory.appending(path: "\(name).mlmodelc"), configuration: configuration)
        }
        detector = try load("ogkalu-ctbd-v4s-fp16", computeUnits.detector)
        encoder = try load("mangaocr-encoder-int8", computeUnits.encoder)
        decoder = try load("mangaocr-decoder-int8", computeUnits.decoder)
        tokenizer = try MangaOCRTokenizer(contentsOf: modelDirectory.appending(path: "vocab.txt"))
        self.threshold = threshold
    }

    /// Finds and reads every text block on a page, in reading order.
    public func recognize(page image: CGImage) throws -> (OCRPage, OCRTimings) {
        var timings = OCRTimings()
        let clock = ContinuousClock()
        let started = clock.now
        let detections = try detect(image)
        timings.detection = clock.now - started

        let bubbles = detections.filter { $0.label == .bubble }.map(\.box)
        let texts = detections.filter { $0.label != .bubble }
        let order = ReadingOrder.order(texts.map {
            ReadingOrder.Item(box: $0.box, bubble: ReadingOrder.containingBubble(of: $0.box, in: bubbles))
        })
        let recognitionStart = clock.now
        var blocks: [OCRBlock] = []
        for index in order {
            let detection = texts[index]
            let text = try read(detection.box, in: image)
            guard !text.isEmpty else { continue }
            let pixels = detection.box.pixels(in: CGSize(width: image.width, height: image.height))
            blocks.append(OCRBlock(
                box: detection.box, text: text, vertical: TextOrientation.isVertical(pixelSize: pixels.size, text: text),
                kind: detection.label == .textInBubble ? .bubbleText : .freeText, score: detection.score
            ))
        }
        timings.recognition = clock.now - recognitionStart
        timings.blocks = blocks.count
        return (OCRPage(imageWidth: image.width, imageHeight: image.height, blocks: blocks), timings)
    }

    /// Reads a region the user drew (normalized to the page).
    public func recognize(region: NormalizedRect, in image: CGImage) throws -> OCRBlock {
        let text = try read(region, in: image, padding: 0)
        let pixels = region.pixels(in: CGSize(width: image.width, height: image.height))
        return OCRBlock(box: region, text: text, vertical: TextOrientation.isVertical(pixelSize: pixels.size, text: text), kind: .manual)
    }

    // MARK: Detection

    func detect(_ image: CGImage) throws -> [Detection] {
        try detect(image, threshold: threshold)
    }

    /// Every query's best class, highest score first (for tuning the threshold).
    func detectAll(_ image: CGImage) throws -> [Detection] {
        try detect(image, threshold: 0).sorted { $0.score > $1.score }
    }

    private func detect(_ image: CGImage, threshold: Double) throws -> [Detection] {
        let size = 640
        guard let rgb = ImagePreprocessing.rgbPixels(image, width: size, height: size) else { throw OCRError.imageConversionFailed }
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let plane = size * size
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for pixel in 0..<plane {
                buffer[pixel] = Float(rgb[pixel * 4]) / 255
                buffer[plane + pixel] = Float(rgb[pixel * 4 + 1]) / 255
                buffer[2 * plane + pixel] = Float(rgb[pixel * 4 + 2]) / 255
            }
        }
        let (logits, boxes) = try detectorOutputs(input)
        return DetectionDecoder.decode(logits: logits.floats(), boxes: boxes.floats(), threshold: threshold)
    }

    func detectorOutputs(_ input: MLMultiArray) throws -> (logits: MLMultiArray, boxes: MLMultiArray) {
        let output = try detector.prediction(from: MLDictionaryFeatureProvider(dictionary: ["images": input]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
              let boxes = output.featureValue(for: "boxes")?.multiArrayValue else {
            throw OCRError.unexpectedModelOutput("detector outputs")
        }
        return (logits, boxes)
    }

    // MARK: Recognition

    func read(_ box: NormalizedRect, in image: CGImage, padding: Double = 0.04) throws -> String {
        let pixelBox = box.pixels(in: CGSize(width: image.width, height: image.height))
        let pad = min(pixelBox.width, pixelBox.height) * padding + 2
        let cropRect = pixelBox.insetBy(dx: -pad, dy: -pad).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: cropRect),
              let gray = ImagePreprocessing.grayPixels(crop, width: 224, height: 224) else { throw OCRError.imageConversionFailed }

        let pixels = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float16)
        let plane = 224 * 224
        pixels.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
            for index in 0..<plane {
                // manga-ocr: grayscale → RGB, normalized with mean 0.5 and std 0.5.
                let value = Float16((Float(gray[index]) / 255 - 0.5) / 0.5)
                buffer[index] = value
                buffer[plane + index] = value
                buffer[2 * plane + index] = value
            }
        }
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["pixel_values": pixels]))
        guard let hidden = encoded.featureValue(for: "encoder_hidden_states")?.multiArrayValue else {
            throw OCRError.unexpectedModelOutput("encoder_hidden_states")
        }
        return tokenizer.decode(try decode(hidden))
    }

    /// Greedy decoding: feed the tokens so far, take the most likely next token, stop at [SEP].
    func decode(_ hidden: MLMultiArray, maxLength: Int = 300) throws -> [Int32] {
        var ids: [Int32] = [MangaOCRTokenizer.startToken]
        while ids.count < maxLength {
            let input = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
            input.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
                for (index, id) in ids.enumerated() { buffer[index] = id }
            }
            let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_ids": input, "encoder_hidden_states": hidden,
            ]))
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                throw OCRError.unexpectedModelOutput("decoder logits")
            }
            let scores = logits.floats()
            var next: Int32 = 0
            for index in scores.indices where scores[index] > scores[Int(next)] { next = Int32(index) }
            if next == MangaOCRTokenizer.endToken { break }
            ids.append(next)
        }
        return Array(ids.dropFirst())
    }
}

extension MLMultiArray {
    /// All values as Float in logical (row-major) order. Core ML may pad rows
    /// (e.g. the detector's [1, 300, 3] float16 logits use strides [9600, 32, 1]),
    /// so values are read through the strides rather than as one contiguous run.
    func floats() -> [Float] {
        let shape = self.shape.map(\.intValue)
        let strides = self.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var offsets = [Int](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        for logical in 0..<count {
            offsets[logical] = zip(index, strides).reduce(0) { $0 + $1.0 * $1.1 }
            var dimension = shape.count - 1
            while dimension >= 0 {
                index[dimension] += 1
                if index[dimension] < shape[dimension] { break }
                index[dimension] = 0
                dimension -= 1
            }
        }
        switch dataType {
        case .float16:
            return withUnsafeBufferPointer(ofType: Float16.self) { buffer in offsets.map { Float(buffer[$0]) } }
        case .float32:
            return withUnsafeBufferPointer(ofType: Float.self) { buffer in offsets.map { buffer[$0] } }
        case .double:
            return withUnsafeBufferPointer(ofType: Double.self) { buffer in offsets.map { Float(buffer[$0]) } }
        default:
            return (0..<count).map { self[$0].floatValue }
        }
    }
}

enum ImagePreprocessing {
    /// RGBA8 pixels resized (high-quality interpolation) to exactly width × height.
    static func rgbPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// 8-bit grayscale pixels resized to exactly width × height.
    static func grayPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            // Transparent areas become white, like paper.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
