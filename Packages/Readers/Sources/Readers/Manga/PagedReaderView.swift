import Core
import SwiftUI

struct PagedReaderView: View {
    let model: MangaReaderModel
    /// Pages stay out of these (the pager itself runs edge to edge, so paging lines up).
    var sideInsets = SideInsets()
    let onOpenChapter: (ReaderChapter) -> Void
    @State private var position: Int?
    @State private var lastSlots: [[Int]] = []
    /// A tap's page turn is animating: swiping is held off until it lands.
    @State private var turning = false
    /// The scroll offset and page width, to notice a page left part-way.
    @State private var offset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    /// Going back to the page being read after a size change.
    @State private var realigning = false
    @FocusState private var focused: Bool

    private var slots: [[Int]] { model.slots }
    /// Pages built on each side of the current one.
    static let builtAround = 2
    private var endIndex: Int { slots.count }
    private var isRightToLeft: Bool { model.settings.direction == .rightToLeft }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    // Not lazy: the pages next to the current one are always built (a lazily
                    // created page drew a black frame as it slid in); pages further
                    // away are empty placeholders, so long chapters stay cheap.
                    HStack(spacing: 0) {
                        ForEach(0...endIndex, id: \.self) { index in
                            Group {
                                if index < endIndex, abs(index - (position ?? 0)) > Self.builtAround {
                                    Color.clear
                                } else if index < endIndex {
                                    ZoomableContainer {
                                        // Taps are handled inside the zoomable content: the native
                                        // zoom view receives touches/clicks before outer gestures.
                                        SpreadView(model: model, pages: slots[index], sideInsets: sideInsets)
                                            .contentShape(.rect)
                                            .onTapGesture(coordinateSpace: .global) { location in
                                                let frame = geometry.frame(in: .global)
                                                handleTap(at: location.x - frame.minX, width: frame.width)
                                            }
                                            .manualSelectionGesture(model)
                                    }
                                } else {
                                    EndOfChapterView(model: model, onOpenChapter: onOpenChapter)
                                        .contentShape(.rect)
                                        .onTapGesture { model.showsChrome.toggle() }
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollDisabled(model.isSelecting || turning)
                .scrollPosition(id: $position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in offset = x }
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { snapIfNeeded(proxy) }
                }
                .onChange(of: turning) { _, isTurning in
                    if !isTurning { snapIfNeeded(proxy) }
                }
                .onAppear { pageWidth = geometry.size.width }
                .onChange(of: geometry.size) { _, size in
                    pageWidth = size.width
                    realign(proxy)
                }
                .onChange(of: slots) { _, newSlots in
                    // Spreads toggled or rotated: stay on the same page, or the one just looked up on.
                    position = SpreadLayout.slotIndex(containing: model.pageToKeep, in: newSlots)
                    lastSlots = newSlots
                    realign(proxy)
                }
                .onChange(of: position) { _, index in
                    // Mid-resize the scroll view reports whatever page its old offset now falls
                    // on; that isn't a page being read.
                    guard let index, !realigning, geometry.size.width == pageWidth else { return }
                    if index >= endIndex {
                        model.reachedEnd()
                    } else if slots.indices.contains(index) {
                        model.pagesShown(first: slots[index].min() ?? 0, lastVisible: slots[index].max() ?? 0)
                    }
                }
                .scrollIndicators(.hidden)
                // Safe-area insets (notch, Mac sidebar) would offset each page and break paging.
                .contentMargins(0, for: .scrollContent)
                .ignoresSafeArea()
                .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
            }
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("reader.paged")
        .accessibilityValue("Page \(model.currentPage + 1) of \(model.pageCount)" + alignmentNote)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { turn(physicalLeft: true); return .handled }
        .onKeyPress(.rightArrow) { turn(physicalLeft: false); return .handled }
        .onKeyPress(.space) { move(by: 1); return .handled }
        .onChange(of: model.pageRequest) { _, request in
            if let request { move(by: request.delta) }
        }
        .onAppear {
            focused = true
            lastSlots = slots
            position = SpreadLayout.slotIndex(containing: model.pageToKeep, in: slots)
        }
        .onChange(of: model.jumpTarget) { _, target in
            guard target != nil, let page = model.consumeJump() else { return }
            position = SpreadLayout.slotIndex(containing: page, in: slots)
        }
    }

    /// Folding the iPhone Duo (or rotating) changes the page width while the scroll offset
    /// stays put in points, so it falls on another page: often one not built yet (a black
    /// screen), and the next swipe went on from there, far from the page being read. Goes back
    /// to that page once the new size is laid out.
    private func realign(_ proxy: ScrollViewProxy) {
        let keep = SpreadLayout.slotIndex(containing: model.pageToKeep, in: slots)
        realigning = true
        position = keep
        Task { @MainActor in
            proxy.scrollTo(keep, anchor: .leading)
            // Again after the fold's animation has settled the final size.
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(keep, anchor: .leading)
            position = keep
            realigning = false
        }
    }

    /// `x` is in screen orientation (global coordinates are never mirrored for RTL).
    private func handleTap(at x: CGFloat, width: CGFloat) {
        // Releasing a long press also ends a tap; it started a selection, not a page turn.
        guard !model.isSelecting else { return }
        if x < width / 3 {
            turn(physicalLeft: true)
        } else if x > width * 2 / 3 {
            turn(physicalLeft: false)
        } else {
            model.showsChrome.toggle()
        }
    }

    /// In RTL, the left side moves forward.
    private func turn(physicalLeft: Bool) {
        move(by: physicalLeft == isRightToLeft ? 1 : -1)
    }

    private func move(by delta: Int) {
        let target = min(max((position ?? 0) + delta, 0), endIndex)
        // A swipe during the animation used to leave the page stuck half-way.
        turning = true
        withAnimation(.easeInOut(duration: 0.25)) { position = target } completion: { turning = false }
    }

    /// Debug builds: whether the pager sits on a page boundary, for the page-turn UI tests.
    private var alignmentNote: String {
        #if DEBUG
        guard pageWidth > 0 else { return "" }
        let remainder = abs(offset).truncatingRemainder(dividingBy: pageWidth)
        return remainder > 1 && remainder < pageWidth - 1 ? ", part-way" : ", aligned"
        #else
        ""
        #endif
    }

    /// If scrolling settled between two pages, finish onto the current one.
    private func snapIfNeeded(_ proxy: ScrollViewProxy) {
        guard pageWidth > 0, !turning, let position else { return }
        let remainder = abs(offset).truncatingRemainder(dividingBy: pageWidth)
        guard remainder > 1, remainder < pageWidth - 1 else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(position, anchor: .leading) }
    }
}

/// One or two pages side by side. In RTL the environment mirrors the HStack,
/// so the lower page number sits on the right like a printed manga.
private struct SpreadView: View {
    let model: MangaReaderModel
    let pages: [Int]
    let sideInsets: SideInsets
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(pages, id: \.self) { page in
                PageImageView(chapterId: model.chapter.chapterId, page: page,
                              aspectRatio: model.aspectRatio(of: page), pages: model.pages)
                    .overlay { OCRTextLayer(model: model, page: page) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The insets are the screen's left and right; this view may be mirrored (right to left).
        .padding(.leading, layoutDirection == .rightToLeft ? sideInsets.right : sideInsets.left)
        .padding(.trailing, layoutDirection == .rightToLeft ? sideInsets.left : sideInsets.right)
        // A little room above the progress bar along the screen's bottom edge.
        .padding(.bottom, 10)
    }
}

/// The screen's left and right safe areas, in screen terms.
struct SideInsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0

    init() {}

    /// From a geometry's insets (laid out left to right).
    init(_ insets: EdgeInsets) {
        left = insets.leading
        right = insets.trailing
    }
}

struct EndOfChapterView: View {
    let model: MangaReaderModel
    let onOpenChapter: (ReaderChapter) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("End of \(model.chapter.title)")
                .font(.title3.bold())
            if let next = model.nextChapter {
                Button {
                    onOpenChapter(next)
                } label: {
                    Label("Read \(next.title)", systemImage: "arrow.forward.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No more chapters in this series.")
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, .leftToRight)
    }
}
