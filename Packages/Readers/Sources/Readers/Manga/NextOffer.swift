import SwiftUI

/// What the end of a chapter or volume offers when the app knows more than the series' next
/// chapter (reading in a reading list). Without one, the readers offer the series' next as before.
public struct NextOffer: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public var chapter: ReaderChapter
        public var label: String
        public var detail: String?
        /// Being fetched before it opens (another series).
        public var isOpening = false
        /// Why it couldn't be opened; the reader stays.
        public var problem: String?

        public init(chapter: ReaderChapter, label: String, detail: String? = nil) {
            self.chapter = chapter
            self.label = label
            self.detail = detail
        }
    }

    /// What the list has after the item being read.
    public enum ListNext: Equatable, Sendable {
        case next(ReaderChapter, label: String, detail: String?)
        case end(detail: String?)
        /// The item isn't in the list (any more): the series' next, as without a list.
        case notInList
    }

    /// Above the choices (the list ended), with what was passed over.
    public var heading: String?
    public var headingDetail: String?
    public var primary: Choice?
    public var secondary: Choice?

    public init(heading: String? = nil, headingDetail: String? = nil, primary: Choice? = nil, secondary: Choice? = nil) {
        self.heading = heading
        self.headingDetail = headingDetail
        self.primary = primary
        self.secondary = secondary
    }

    /// A choice is being fetched: the other can't be pressed meanwhile.
    public var isOpening: Bool { primary?.isOpening == true || secondary?.isOpening == true }

    /// This offer, remade (the list changed), keeping what `previous` showed for the same
    /// chapters: the spinner of one being opened and the reason one couldn't be.
    public func carrying(from previous: NextOffer?) -> NextOffer {
        guard let previous else { return self }
        var offer = self
        let old = [previous.primary, previous.secondary].compactMap(\.self)
        for path in [\NextOffer.primary, \NextOffer.secondary] {
            guard let id = offer[keyPath: path]?.chapter.chapterId, let match = old.first(where: { $0.chapter.chapterId == id }) else { continue }
            offer[keyPath: path]?.isOpening = match.isOpening
            offer[keyPath: path]?.problem = match.problem
        }
        return offer
    }

    /// The offer for reading in the list `listTitle`: the list's next first, the series' next as a
    /// second, smaller choice (left out when it's the same chapter).
    public static func reading(in listTitle: String, _ list: ListNext, seriesNext: ReaderChapter?) -> NextOffer {
        let series = seriesNext.map { Choice(chapter: $0, label: "Next in series: \($0.title)") }
        switch list {
        case .next(let chapter, let label, let detail):
            return NextOffer(primary: Choice(chapter: chapter, label: "Next in \u{201C}\(listTitle)\u{201D}: \(label)", detail: detail),
                             secondary: series?.chapter.chapterId == chapter.chapterId ? nil : series)
        case .end(let detail):
            return NextOffer(heading: "End of \u{201C}\(listTitle)\u{201D}", headingDetail: detail, primary: series)
        case .notInList:
            return NextOffer(primary: series)
        }
    }
}

/// The offer's buttons: the main one prominent, the other bordered, each with its line under it.
struct NextOfferButtons: View {
    let offer: NextOffer
    /// What to say when there's nothing to open.
    let none: String
    let open: (ReaderChapter) -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let heading = offer.heading {
                Text(heading).font(.headline)
                if let detail = offer.headingDetail { Text(detail).font(.caption).opacity(0.8) }
            }
            if let primary = offer.primary {
                choice(primary, prominent: true).accessibilityIdentifier("reader.next")
            }
            if let secondary = offer.secondary {
                choice(secondary, prominent: false).accessibilityIdentifier("reader.nextInSeries")
            }
            if offer.primary == nil, offer.heading == nil {
                Text(none).opacity(0.8)
            }
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder private func choice(_ choice: NextOffer.Choice, prominent: Bool) -> some View {
        VStack(spacing: 4) {
            let button = Button {
                open(choice.chapter)
            } label: {
                HStack {
                    if choice.isOpening { ProgressView().controlSize(.small) }
                    Label(choice.label, systemImage: prominent ? "arrow.forward.circle.fill" : "arrow.forward")
                        .lineLimit(2)
                }
            }
            .disabled(offer.isOpening)
            if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
            if let problem = choice.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else if let detail = choice.detail {
                Text(detail).font(.caption).opacity(0.8)
            }
        }
    }
}
