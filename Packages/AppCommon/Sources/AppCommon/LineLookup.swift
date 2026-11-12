import Foundation
import Lookup
import Observation

/// Looks up a tapped word in a subtitle line and keeps what the popup and the
/// highlight need. Shared by the player, transcripts and the live feed.
@MainActor @Observable
public final class LineLookup {
    public var popup: LookupPopupModel?
    /// The looked-up characters: which line (a caller-chosen key) and the character range.
    public private(set) var highlight: (key: String, range: Range<Int>)?
    @ObservationIgnored private let service: LookupService

    public init(service: LookupService) {
        self.service = service
    }

    /// Looks up the word at `characterIndex` of `text` (newlines are dropped first) and
    /// opens the popup; cards mined from it get `context`.
    public func lookUp(_ text: String, characterIndex: Int, key: String, context: (any MiningContext)?) {
        let sentence = TappableLine.sentence(text)
        let offset = String(sentence.prefix(characterIndex)).utf16.count
        Task {
            let page = await service.lookup(text: sentence, utf16Offset: offset, showSource: true)
            if let source = page.source, !page.results.isEmpty {
                let start = Self.characterIndex(utf16: source.utf16Offset, in: sentence)
                let end = Self.characterIndex(utf16: source.utf16Offset + source.utf16Length, in: sentence)
                highlight = (key, start..<max(end, start + 1))
            } else {
                highlight = nil
            }
            popup = LookupPopupModel(page: page, context: context)
        }
    }

    public func highlightedRange(for key: String) -> Range<Int>? {
        highlight?.key == key ? highlight?.range : nil
    }

    public func close() {
        popup = nil
        highlight = nil
    }

    public static func characterIndex(utf16 offset: Int, in text: String) -> Int {
        let index = String.Index(utf16Offset: min(offset, text.utf16.count), in: text)
        return text.distance(from: text.startIndex, to: index)
    }
}

/// For lines looked up without a connection: the card keeps its source, without media.
public struct TextMiningContext: MiningContext {
    public var miscInfo: String

    public init(miscInfo: String) {
        self.miscInfo = miscInfo
    }

    public func pictureData() async -> Data? { nil }
}

nonisolated public enum CardSource {
    /// "Star Captain — S1E1 · 12:34" for the card's MiscInfo.
    public static func miscInfo(show: String, episode: String?, time: Double) -> String {
        let total = Int(max(time, 0))
        let stamp = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        return [show, [episode, stamp].compactMap(\.self).joined(separator: " · ")].joined(separator: " — ")
    }
}
