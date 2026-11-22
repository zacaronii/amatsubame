import CoreGraphics
import OCR
import SwiftUI

/// A bubble's recognized text set over the bubble itself while one of its words is looked up,
/// in the same direction and about the same size as the lettering. Where a tap on the picture
/// can only estimate which character it hit, a tap here is on a real one; the word showing
/// in the popup is marked.
struct OCRTypesetBlock: View {
    let block: OCRBlock
    /// The block's rect on the page, in the layer's coordinates.
    let rect: CGRect
    var highlight: Range<Int>?
    let onTap: (Int) -> Void

    /// The characters in lines: columns right to left for vertical text, rows otherwise.
    static func lines(_ block: OCRBlock) -> [[(index: Int, character: Character)]] {
        let characters = Array(block.text.enumerated()).map { (index: $0.offset, character: $0.element) }
        guard !characters.isEmpty else { return [] }
        let measured = (block.lines ?? []).map(\.cgRect)
        var counts: [Int]
        if !measured.isEmpty, measured.count <= characters.count {
            counts = TextLayout.characterCounts(measured.map { block.vertical ? $0.height : $0.width }, total: characters.count)
        } else {
            // No measured lines: as many as would make the characters about square.
            let across = block.vertical ? block.box.width : block.box.height, along = block.vertical ? block.box.height : block.box.width
            let lines = max(1, min(characters.count, Int((Double(characters.count) * across / max(along, 0.0001)).squareRoot().rounded())))
            let perLine = Int((Double(characters.count) / Double(lines)).rounded(.up))
            counts = Array(repeating: perLine, count: lines)
        }
        var result: [[(index: Int, character: Character)]] = []
        var next = 0
        for count in counts where next < characters.count {
            let end = min(next + count, characters.count)
            result.append(Array(characters[next..<end]))
            next = end
        }
        if next < characters.count, !result.isEmpty { result[result.count - 1] += characters[next...] }
        return result
    }

    /// Marks that turn on their side in vertical text, and the ones that sit in a corner.
    static let turned: Set<Character> = ["ー", "〜", "～", "…", "‥", "—", "―", "－", "「", "」", "『", "』", "（", "）", "(", ")", "【", "】", "〈", "〉", "《", "》", "＝", "："]
    static let cornered: Set<Character> = ["、", "。", "，", "．"]

    var body: some View {
        let lines = Self.lines(block)
        let longest = max(lines.map(\.count).max() ?? 1, 1)
        // A cell per character, as large as the bubble allows, a little larger than the
        // lettering it covers when the bubble is small.
        let fit = block.vertical ? min(rect.width / CGFloat(max(lines.count, 1)), rect.height / CGFloat(longest))
            : min(rect.height / CGFloat(max(lines.count, 1)), rect.width / CGFloat(longest))
        // Never too small to tap, nor as large as display lettering (a title page's).
        let cell = min(max(fit, 17), 30)
        let plate = Group {
            if block.vertical {
                HStack(alignment: .top, spacing: 0) {
                    // Right to left: the first column is on the right.
                    ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                        VStack(spacing: 0) { ForEach(line, id: \.index) { glyph in cellView(glyph, size: cell) } }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) { ForEach(line, id: \.index) { glyph in cellView(glyph, size: cell) } }
                    }
                }
            }
        }
        plate
            .padding(4)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.tint.opacity(0.6), lineWidth: 1) }
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .environment(\.layoutDirection, .leftToRight)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ocr.overlay")
    }

    private func cellView(_ glyph: (index: Int, character: Character), size: CGFloat) -> some View {
        let turned = block.vertical && Self.turned.contains(glyph.character)
        let cornered = block.vertical && Self.cornered.contains(glyph.character)
        return Text(String(glyph.character))
            .font(.system(size: size * 0.84, weight: .medium))
            .foregroundStyle(.primary)
            .rotationEffect(.degrees(turned ? 90 : 0))
            .offset(x: cornered ? size * 0.32 : 0, y: cornered ? -size * 0.32 : 0)
            .frame(width: size, height: size)
            .background(highlight?.contains(glyph.index) == true ? AnyShapeStyle(.tint.opacity(0.45)) : AnyShapeStyle(.clear))
            .contentShape(.rect)
            .onTapGesture { onTap(glyph.index) }
            .accessibilityLabel(String(glyph.character))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("ocr.overlay.character")
    }
}
