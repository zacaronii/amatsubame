import CoreGraphics
import Foundation

/// A raw detection from the text and bubble detector.
public struct Detection: Equatable, Sendable {
    public enum Label: Int, Sendable {
        case bubble = 0
        case textInBubble = 1
        case freeText = 2
    }

    public var label: Label
    public var score: Double
    public var box: NormalizedRect
}

/// Turns the detector's raw outputs into boxes. The model (RT-DETRv4-S) returns 300
/// queries, each with three class logits and a normalized (cx, cy, w, h) box over
/// the whole page, since the page is squashed to 640×640 without letterboxing.
public enum DetectionDecoder {
    public static let queryCount = 300

    /// - Parameters:
    ///   - logits: 300×3 class logits, row-major.
    ///   - boxes: 300×4 (cx, cy, w, h), row-major.
    public static func decode(logits: [Float], boxes: [Float], threshold: Double) -> [Detection] {
        let count = min(logits.count / 3, boxes.count / 4)
        var detections: [Detection] = []
        for query in 0..<count {
            var bestLabel = 0
            var bestLogit = -Float.infinity
            for label in 0..<3 where logits[query * 3 + label] > bestLogit {
                bestLogit = logits[query * 3 + label]
                bestLabel = label
            }
            let score = 1 / (1 + exp(-Double(bestLogit)))
            guard score >= threshold else { continue }
            let cx = Double(boxes[query * 4]), cy = Double(boxes[query * 4 + 1])
            let w = Double(boxes[query * 4 + 2]), h = Double(boxes[query * 4 + 3])
            let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !rect.isNull, rect.width > 0.002, rect.height > 0.002 else { continue }
            detections.append(Detection(label: Detection.Label(rawValue: bestLabel)!, score: score, box: NormalizedRect(rect)))
        }
        return suppressOverlaps(detections)
    }

    /// DETR-style models rarely duplicate boxes, but keep only the best of any
    /// same-class pair that overlaps heavily.
    static func suppressOverlaps(_ detections: [Detection], iou: Double = 0.6) -> [Detection] {
        var kept: [Detection] = []
        for detection in detections.sorted(by: { $0.score > $1.score }) {
            let duplicate = kept.contains { $0.label == detection.label && $0.box.intersectionOverUnion(detection.box) > iou }
            if !duplicate { kept.append(detection) }
        }
        return kept
    }
}
