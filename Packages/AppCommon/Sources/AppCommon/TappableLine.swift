import Core
import SwiftUI

/// A subtitle line where every character can be tapped. Taps report the character's
/// index in the line's one-line form (newlines from the file removed), which is what
/// lookups and the card's sentence use.
public struct TappableLine: View {
    public enum Style: Sendable {
        /// White with a shadow on a dark plate, over video.
        case overlay
        /// Plain text, for transcript lists.
        case plain
    }

    public let text: String
    public var highlighted: Range<Int>?
    /// Word marks by character index (from `WordMarkCache`): not in Anki or still learning.
    public var marks: [Int: WordMarkState] = [:]
    public var fontSize: CGFloat
    public var style = Style.plain
    public var alignment = Alignment.center
    public let onTap: (Int) -> Void

    public init(text: String, highlighted: Range<Int>? = nil, marks: [Int: WordMarkState] = [:], fontSize: CGFloat,
                style: Style = .plain, alignment: Alignment = .center, onTap: @escaping (Int) -> Void) {
        self.text = text
        self.highlighted = highlighted
        self.marks = marks
        self.fontSize = fontSize
        self.style = style
        self.alignment = alignment
        self.onTap = onTap
    }

    /// The line without its line breaks.
    /// Letters, kana, kanji and digits: what a tap can look up (not spaces or punctuation).
    public static func isWordCharacter(_ character: Character) -> Bool {
        !character.isWhitespace && !character.isPunctuation && !character.isSymbol
    }

    public static func sentence(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined()
    }

    /// Characters with their index in the sentence; nil marks a line break from the file.
    private var glyphs: [(index: Int, character: Character)?] {
        var result: [(Int, Character)?] = []
        var index = 0
        for character in text {
            if character.isNewline {
                result.append(nil)
            } else {
                result.append((index, character))
                index += 1
            }
        }
        return result
    }

    public var body: some View {
        let line = SubtitleFlow(spacing: 0, lineSpacing: fontSize * 0.25, centered: alignment == .center) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                if let glyph {
                    Text(String(glyph.character))
                        .font(.system(size: fontSize, weight: style == .overlay ? .semibold : .regular))
                        .foregroundStyle(style == .overlay ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .padding(.vertical, 2)
                        .overlay(alignment: .bottom) { WordMarkLine(state: marks[glyph.index]) }
                        .background(highlighted?.contains(glyph.index) == true ? AnyShapeStyle(.tint.opacity(0.75)) : AnyShapeStyle(.clear))
                        .contentShape(.rect)
                        // Between words (a space, punctuation) there's nothing to look up.
                        .onTapGesture { if Self.isWordCharacter(glyph.character) { onTap(glyph.index) } }
                        .layoutValue(key: SubtitleFlow.NoBreakBefore.self, value: SubtitleFlow.staysWithPrevious(glyph.character))
                } else {
                    SubtitleFlow.LineBreak()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.sentence(text))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("subtitle.line")
        .accessibilityAction { onTap(0) }

        switch style {
        case .overlay:
            line
                .shadow(color: .black, radius: 0, x: 1, y: 1)
                .shadow(color: .black.opacity(0.9), radius: 3)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.35), in: .rect(cornerRadius: 6))
        case .plain:
            line
        }
    }
}

/// The underline under one character of a marked word: solid in the accent for words not in
/// Anki, dotted grey for words still being learned.
public struct WordMarkLine: View {
    public let state: WordMarkState?

    public init(state: WordMarkState?) {
        self.state = state
    }

    public var body: some View {
        switch state {
        case .notInAnki?:
            Rectangle().fill(.tint).frame(height: 2)
        case .learning?:
            DottedLine().stroke(Color(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 4]))
                .frame(height: 2)
        default:
            EmptyView()
        }
    }

    nonisolated private struct DottedLine: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// Lays characters out in rows, wrapping at the available width and at `LineBreak`s.
public struct SubtitleFlow: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat
    /// Centered rows (overlay) or leading-aligned (transcripts).
    public var centered = true

    public init(spacing: CGFloat, lineSpacing: CGFloat, centered: Bool = true) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.centered = centered
    }

    /// A zero-size marker that forces a new row.
    public struct LineBreak: View {
        public init() {}
        public var body: some View { Color.clear.frame(width: 0, height: 0).layoutValue(key: IsBreak.self, value: true) }
    }

    /// Closing punctuation (。、」…) and small kana never start a row; they stay at the end of the one before.
    public struct NoBreakBefore: LayoutValueKey {
        public static let defaultValue = false
    }

    nonisolated public static func staysWithPrevious(_ character: Character) -> Bool {
        "。、，．！？!?」』）)】〉》ー…‥ゃゅょっぁぃぅぇぉャュョッァィゥェォ".contains(character)
    }

    struct IsBreak: LayoutValueKey {
        static let defaultValue = false
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            if subview[IsBreak.self] {
                rows.append(Row())
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth,
               !subview[NoBreakBefore.self] {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, maxWidth: bounds.width) {
            var x = bounds.minX + (centered ? (bounds.width - row.width) / 2 : 0)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
        for subview in subviews where subview[IsBreak.self] {
            subview.place(at: bounds.origin, proposal: .zero)
        }
    }
}

/// What the word marks mean, above a transcript.
public struct WordMarkLegend: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 16) {
            item("未", "not in Anki", state: .notInAnki)
            item("習", "learning", state: .learning)
            Text("known: no mark")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func item(_ sample: String, _ label: String, state: WordMarkState) -> some View {
        HStack(spacing: 4) {
            Text(sample)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .padding(.vertical, 2)
                .overlay(alignment: .bottom) { WordMarkLine(state: state) }
            Text(label)
        }
    }
}

