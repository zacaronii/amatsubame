import CoreGraphics
import Lookup
import OCR
import SwiftUI

/// Invisible tappable text over a page. Only the detected blocks take taps, so
/// taps elsewhere fall through to page turning and the controls. In selection mode
/// (after a long press) the page captures a drag and draws the box in its own
/// coordinates, so no conversion between coordinate spaces is needed.
struct OCRTextLayer: View {
    static let space = "ocrTextLayer"
    let model: MangaReaderModel
    let page: Int
    /// The part of the page this layer covers, as a fraction of its width from its left edge
    /// (half of a split wide page); the layer is that part's size.
    var visible: ClosedRange<Double> = 0...1

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = geometry.frame(in: .global)
            let place = Placement(layer: size, visible: visible)
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let text = model.pageText[page] {
                    // Only the blocks whose middle is in this part: one across the gutter belongs to
                    // the half holding most of it, and the other half's can't be tapped through this one.
                    ForEach(Array(text.blocks.enumerated()).filter { Self.isShown($0.element.box, in: visible) },
                            id: \.offset) { _, block in
                        let rect = place.rect(block.box)
                        Rectangle()
                            .fill(.clear)
                            .overlay {
                                if model.settings.showsTextBoxes {
                                    RoundedRectangle(cornerRadius: 3).stroke(.tint.opacity(0.7), lineWidth: 1.5)
                                }
                            }
                            .frame(width: rect.width, height: rect.height)
                            .contentShape(.rect)
                            // Measured in the layer's space so the block's own rect applies directly.
                            .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                                // The character whose place in the lettering the tap is in
                                // (measured from the picture; estimated on pages without that).
                                let index = TextLayout.characterIndex(of: location, in: rect, cells: block.characterRects(boxSize: rect.size))
                                model.lookUp(block, page: page, characterIndex: index, anchor: rect.offsetBy(dx: frame.minX, dy: frame.minY))
                            }
                            #if os(macOS)
                            // Look Up on Hover: the character under the pointer, as a click would take it.
                            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                                switch phase {
                                case .active(let location):
                                    let index = TextLayout.characterIndex(of: location, in: rect, cells: block.characterRects(boxSize: rect.size))
                                    model.hovered(block, page: page, characterIndex: index, anchor: rect.offsetBy(dx: frame.minX, dy: frame.minY))
                                case .ended:
                                    model.hoverEnded(block, page: page)
                                }
                            }
                            #endif
                            .accessibilityElement()
                            .accessibilityLabel(block.text)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("ocr.block")
                            // `.position` moves the real frame (taps and accessibility follow);
                            // `.offset` would only move the drawing.
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                if let overlay = model.textOverlay(page: page), let range = overlay.highlight, Self.isShown(overlay.block.box, in: visible) {
                    // The word being looked up, marked on the lettering itself: nothing is drawn
                    // but a tint over its characters, so it shows what the tap was taken for.
                    let rect = place.rect(overlay.block.box)
                    ForEach(Array(Self.marks(overlay.block, range: range, in: rect).enumerated()), id: \.offset) { _, mark in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.tint.opacity(0.3))
                            .frame(width: mark.width, height: mark.height)
                            .position(x: mark.midX, y: mark.midY)
                            .allowsHitTesting(false)
                            .accessibilityElement()
                            .accessibilityIdentifier("ocr.highlight")
                    }
                }
                #if os(macOS)
                // A key pressed while the pointer already rests on a word counts too.
                Color.clear.allowsHitTesting(false)
                    .onChange(of: HoverModifiers.shared.flags.rawValue) { model.lookUpHovered() }
                #endif
                if model.isSelecting {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                                .onChanged { drag in
                                    let rect = CGRect(origin: drag.startLocation, size: .zero)
                                        .union(CGRect(origin: drag.location, size: .zero))
                                        .intersection(CGRect(origin: .zero, size: size))
                                    // Kept in the whole page's terms (a half's layer is offset into it).
                                    model.selection = (page, rect.offsetBy(dx: place.offset, dy: 0))
                                }
                                .onEnded { _ in
                                    model.finishSelection(pageSize: place.page, anchorOrigin: CGPoint(x: frame.minX - place.offset, y: frame.minY))
                                }
                        )
                }
                if let selection = model.selection, selection.page == page {
                    Rectangle()
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(.tint.opacity(0.12))
                        .frame(width: selection.rect.width, height: selection.rect.height)
                        .position(x: selection.rect.midX - place.offset, y: selection.rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        // Offsets are physical positions on the page, even in a right-to-left reader.
        .environment(\.layoutDirection, .leftToRight)
    }
}

extension OCRTextLayer {
    /// A block is in the part of the page shown when its middle is.
    static func isShown(_ box: NormalizedRect, in visible: ClosedRange<Double>) -> Bool {
        visible.contains(box.x + box.width / 2)
    }

    /// Where the page's normalised boxes go in a layer covering `visible` of the page:
    /// `x′ = (x − visible.lower) × page width`, the page being `layer.width / visible's span` wide.
    struct Placement {
        let page: CGSize
        let offset: CGFloat

        init(layer: CGSize, visible: ClosedRange<Double>) {
            let span = max(visible.upperBound - visible.lowerBound, 0.0001)
            page = CGSize(width: layer.width / span, height: layer.height)
            offset = visible.lowerBound * page.width
        }

        func rect(_ box: NormalizedRect) -> CGRect {
            box.pixels(in: page).offsetBy(dx: -offset, dy: 0)
        }
    }

    /// The rects to tint for characters `range` of a block drawn in `rect`: one per line the
    /// word runs over, a little larger than the ink.
    static func marks(_ block: OCRBlock, range: Range<Int>, in rect: CGRect) -> [CGRect] {
        // Only where each character's place was measured in the lettering: a mark that's a
        // guess is worse than none.
        guard block.cellsExact == true, let measured = block.cells, measured.count == block.text.count else { return [] }
        let cells = measured.map(\.cgRect)
        var marks: [CGRect] = []
        for index in range where cells.indices.contains(index) {
            let cell = CGRect(x: rect.minX + cells[index].minX * rect.width, y: rect.minY + cells[index].minY * rect.height,
                              width: cells[index].width * rect.width, height: cells[index].height * rect.height)
            // The same line as the one before: one mark for both.
            if let last = marks.last,
               block.vertical ? abs(last.midX - cell.midX) < cell.width / 2 : abs(last.midY - cell.midY) < cell.height / 2 {
                marks[marks.count - 1] = last.union(cell)
            } else {
                marks.append(cell)
            }
        }
        // Lettering that isn't in lines (a title drawn at angles) measures as one "line" as wide
        // as the block: its places aren't character-shaped, so there's nothing exact to mark.
        let count = CGFloat(range.count)
        let along = marks.reduce(0) { $0 + (block.vertical ? $1.height : $1.width) } / max(count, 1)
        let across = marks.map { block.vertical ? $0.width : $0.height }.max() ?? 0
        guard along > 0, across <= along * 2.5 else { return [] }
        return marks.map { $0.insetBy(dx: -2, dy: -2) }
    }
}

extension View {
    /// Long-press anywhere on a page to start drawing a box for manual OCR. Only a
    /// long press is recognized here (it fails as soon as the finger moves), so
    /// swipes and taps keep working; the box is drawn in `ManualSelectionOverlay`.
    func manualSelectionGesture(_ model: MangaReaderModel) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in model.beginSelecting() }
        )
    }
}

/// Shown while selecting: what to do, and a way out. The drag itself is captured by
/// each page's `OCRTextLayer`.
struct ManualSelectionOverlay: View {
    let model: MangaReaderModel

    var body: some View {
        HStack {
            Label("Drag a box over text to read it", systemImage: "text.viewfinder")
            Button("Cancel") { model.cancelSelecting() }
                .buttonStyle(.bordered)
        }
        .font(.callout)
        .padding(10)
        .background(.regularMaterial, in: .capsule)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("reader.selectionOverlay")
    }
}
