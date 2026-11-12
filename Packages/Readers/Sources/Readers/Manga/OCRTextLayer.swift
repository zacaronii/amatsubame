import CoreGraphics
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

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = geometry.frame(in: .global)
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let text = model.pageText[page] {
                    ForEach(Array(text.blocks.enumerated()), id: \.offset) { _, block in
                        let rect = block.box.pixels(in: size)
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
                                let index = TextLayout.characterIndex(
                                    of: location, in: rect,
                                    characterCount: block.text.count, vertical: block.vertical
                                )
                                model.lookUp(block, page: page, characterIndex: index, anchor: rect.offsetBy(dx: frame.minX, dy: frame.minY))
                            }
                            .accessibilityElement()
                            .accessibilityLabel(block.text)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("ocr.block")
                            // `.position` moves the real frame (taps and accessibility follow);
                            // `.offset` would only move the drawing.
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                if model.isSelecting {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                                .onChanged { drag in
                                    let rect = CGRect(origin: drag.startLocation, size: .zero)
                                        .union(CGRect(origin: drag.location, size: .zero))
                                        .intersection(CGRect(origin: .zero, size: size))
                                    model.selection = (page, rect)
                                }
                                .onEnded { _ in model.finishSelection(pageSize: size, anchorOrigin: frame.origin) }
                        )
                }
                if let selection = model.selection, selection.page == page {
                    Rectangle()
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(.tint.opacity(0.12))
                        .frame(width: selection.rect.width, height: selection.rect.height)
                        .position(x: selection.rect.midX, y: selection.rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        // Offsets are physical positions on the page, even in a right-to-left reader.
        .environment(\.layoutDirection, .leftToRight)
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
