import Core
import SwiftUI

struct LongStripReaderView: View {
    let model: MangaReaderModel
    let onOpenChapter: (ReaderChapter) -> Void
    @State private var position = ScrollPosition(idType: Int.self)
    /// Where the strip is scrolled to and how far it can go (auto-scroll moves from there).
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0

    private var endId: Int { model.pageCount }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<model.pageCount, id: \.self) { page in
                        PageImageView(chapterId: model.chapter.chapterId, page: page,
                                      aspectRatio: model.aspectRatio(of: page), pages: model.pages)
                            .overlay { OCRTextLayer(model: model, page: page) }
                            .frame(width: geometry.size.width * model.settings.stripWidth)
                            .id(page)
                    }
                    EndOfChapterView(model: model, onOpenChapter: onOpenChapter)
                        .frame(height: 240)
                        .id(endId)
                }
                .frame(maxWidth: .infinity)
                .scrollTargetLayout()
            }
            .scrollPosition($position, anchor: .top)
            .accessibilityIdentifier("reader.strip")
            .accessibilityValue("Page \(model.currentPage + 1) of \(model.pageCount)")
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.3) { visible in
                guard let first = visible.min(), let last = visible.max() else { return }
                if last >= endId {
                    model.reachedEnd()
                } else {
                    model.pagesShown(first: first, lastVisible: last)
                }
            }
            // In the coordinates `scrollTo(y:)` takes, 0 at the top: the content offset plus the
            // top inset (moving on from the bare offset kept auto-scroll pinned to the top).
            .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                let insets = geometry.contentInsets
                return [geometry.contentOffset.y + insets.top,
                        geometry.contentSize.height + insets.top + insets.bottom - geometry.containerSize.height]
            } action: { _, values in
                offset = values[0]
                maxOffset = values[1]
            }
            // A finger on the strip pauses auto-scroll; it carries on a moment after letting go.
            // (Auto-scroll's own moves settle to idle too: only a finger's count.)
            .onScrollPhaseChange { old, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    model.autoScroll.handScrollBegan()
                case .idle where [.tracking, .interacting, .decelerating].contains(old):
                    model.autoScroll.handScrolled()
                default:
                    break
                }
            }
            .task(id: model.autoScroll.isMoving) { await autoScroll() }
            .onTapGesture {
                guard !model.isSelecting else { return }
                if model.popup != nil { model.popup = nil } else { model.showsChrome.toggle() }
            }
            .manualSelectionGesture(model)
            .scrollDisabled(model.isSelecting)
        }
        // The sides too: the page runs under the iPhone Duo outer screen's camera column, as in
        // the paged reader (the status bar is hidden while reading).
        .ignoresSafeArea(edges: [.bottom, .horizontal])
        .onAppear { position.scrollTo(id: model.currentPage, anchor: .top) }
        .onChange(of: model.jumpTarget) { _, target in
            guard target != nil, let page = model.consumeJump() else { return }
            position.scrollTo(id: page, anchor: .top)
        }
    }

    /// While auto-scroll moves: down at the chosen speed, a frame at a time, until the end.
    private func autoScroll() async {
        guard model.autoScroll.isMoving else { return }
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled, model.autoScroll.isMoving {
            try? await Task.sleep(for: .milliseconds(16))
            let now = clock.now
            let seconds = Double((now - last) / .milliseconds(1)) / 1000
            last = now
            if model.autoScroll.checkIdle() { return }
            // At the end of what's laid out (pages below still loading, or estimated short), it
            // waits for room rather than stopping: the end-of-chapter screen stops it.
            guard offset < maxOffset - 0.5 else { continue }
            let step = AutoScroll.mangaPointsPerSecond(level: model.settings.autoScrollLevel) * min(seconds, 0.1)
            let target = min(offset + step, max(maxOffset, 0))
            position.scrollTo(y: target)
            offset = target
        }
    }
}
