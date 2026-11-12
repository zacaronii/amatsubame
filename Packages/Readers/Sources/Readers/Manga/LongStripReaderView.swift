import Core
import SwiftUI

struct LongStripReaderView: View {
    let model: MangaReaderModel
    let onOpenChapter: (ReaderChapter) -> Void
    @State private var position: Int?

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
            .scrollPosition(id: $position, anchor: .top)
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.3) { visible in
                guard let first = visible.min(), let last = visible.max() else { return }
                if last >= endId {
                    model.reachedEnd()
                } else {
                    model.pagesShown(first: first, lastVisible: last)
                }
            }
            .onTapGesture { if !model.isSelecting { model.showsChrome.toggle() } }
            .manualSelectionGesture(model)
            .scrollDisabled(model.isSelecting)
        }
        // Not the sides: the iPhone Duo's outer screen has its status column there.
        .ignoresSafeArea(edges: .bottom)
        .onAppear { position = model.currentPage }
        .onChange(of: model.jumpTarget) { _, target in
            guard target != nil, let page = model.consumeJump() else { return }
            position = page
        }
    }
}
