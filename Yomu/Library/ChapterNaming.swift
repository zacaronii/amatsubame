import Core
import Foundation
import KavitaKit
import Readers

/// Display names for Kavita's volume/chapter structure.
extension KavitaVolume {
    var displayTitle: String { "Volume \(name)" }
}

extension KavitaChapter {
    func displayTitle(in volume: KavitaVolume?) -> String {
        if isSpecial {
            return [titleName, title, range].compactMap { $0 }.first { !$0.isEmpty } ?? "Special"
        }
        // One file per volume (whole-volume files, or files tagged with a chapter
        // number like "Moonlit Harbor Volume 2"): name it after the volume.
        if let volume, isWholeVolume || volume.chapters.count == 1 {
            return volume.displayTitle
        }
        if let titleName, !titleName.isEmpty { return titleName }
        return "Chapter \(range ?? number)"
    }
}

/// A book's progress in characters as Yomu counts them (Hoshi Reader's rule), never Kavita's
/// percentage: its pages are a book's sections, which vary a lot in length.
struct BookProgress: Equatable {
    var read: Int
    var total: Int
    /// From Kavita's word count until the volume is counted (shown with "~").
    var isEstimate = false

    var fraction: Double { total > 0 ? min(Double(read) / Double(total), 1) : 0 }
    /// "18%", or "~18%" for an estimate.
    var percent: String { (isEstimate ? "~" : "") + SeriesDetailView.percent(read, of: total) }
}

enum BookCharacters {
    /// Kavita's book "word count" is letters ÷ 5 (Kavita 0.9.1.7), a little over Hoshi's count.
    static let lettersPerKavitaWord = 5

    /// One volume: from its count (`BookLength`), or estimated from Kavita's word count before
    /// it's counted. Where reading is, as the reader decides where to open: this device's own
    /// count when it's newer than Kavita's place (or as far), else the start of Kavita's section
    /// (another device read since).
    static func progress(_ chapter: KavitaChapter, length: BookLength?, local: LocalReadingProgress?) -> BookProgress? {
        let local = local.flatMap { local in
            local.page >= chapter.pagesRead || local.updatedAt >= (chapter.lastReadingProgressUtc ?? .distantPast) ? local : nil
        }
        if let length, length.total > 0 {
            let total = length.total
            if chapter.isRead { return BookProgress(read: total, total: total) }
            if let local, let characters = local.characters {
                return BookProgress(read: min(characters, total), total: total)
            }
            return BookProgress(read: length.start(of: chapter.pagesRead), total: total)
        }
        guard let words = chapter.wordCount, words > 0 else { return nil }
        let total = words * lettersPerKavitaWord
        if chapter.isRead { return BookProgress(read: total, total: total, isEstimate: true) }
        if let local, let characters = local.characters {
            return BookProgress(read: min(characters, total), total: total, isEstimate: true)
        }
        let share = chapter.pages > 0 ? Double(chapter.pagesRead) / Double(chapter.pages) : 0
        return BookProgress(read: Int(Double(total) * share), total: total, isEstimate: true)
    }

    /// A whole series: every volume's characters read over all of them (nil when a volume has
    /// neither a count nor a word count).
    static func series(_ chapters: [KavitaChapter], lengths: [Int: BookLength], local: [Int: LocalReadingProgress]) -> BookProgress? {
        let volumes = chapters.map { progress($0, length: lengths[$0.id], local: local[$0.id]) }
        guard !volumes.isEmpty, volumes.allSatisfy({ $0 != nil }) else { return nil }
        let counts = volumes.compactMap(\.self)
        return BookProgress(read: counts.reduce(0) { $0 + $1.read }, total: counts.reduce(0) { $0 + $1.total },
                            isEstimate: counts.contains(where: \.isEstimate))
    }
}

extension AppEnvironment {
    /// A book series' progress from what's saved on the device: its volumes, their counts and
    /// this device's reading. Nil before its volumes have been loaded once.
    func bookProgress(seriesId: Int) -> BookProgress? {
        guard let volumes = try? kavitaLibrary.cachedVolumes(seriesId: seriesId), !volumes.isEmpty else { return nil }
        let contents = KavitaSeriesContents(volumes: volumes)
        let local = Dictionary(((try? readingProgress.progress(seriesId: seriesId)) ?? []).map { ($0.chapterId, $0) },
                               uniquingKeysWith: { first, _ in first })
        return BookCharacters.series(contents.readingOrder + contents.specials,
                                     lengths: (try? bookLengths.lengths(seriesId: seriesId)) ?? [:], local: local)
    }
}

extension KavitaSeriesContents {
    func volume(containing chapter: KavitaChapter) -> KavitaVolume? {
        volumes.first { $0.id == chapter.volumeId }
    }

    func readerChapter(_ chapter: KavitaChapter, series: KavitaSeries) -> ReaderChapter {
        ReaderChapter(
            chapterId: chapter.id, volumeId: chapter.volumeId, seriesId: series.id, libraryId: series.libraryId,
            pages: chapter.pages, title: chapter.displayTitle(in: volume(containing: chapter)),
            seriesTitle: series.displayName
        )
    }

    func nextReaderChapter(after chapter: ReaderChapter, series: KavitaSeries) -> ReaderChapter? {
        self.chapter(after: chapter.chapterId).map { readerChapter($0, series: series) }
    }

    /// Where reading continues, short: "Vol. 1 · p. 11", "Vol. 1 · 0.5%" (books), "Vol. 2" (not
    /// started), "Ch. 5 · p. 3". `separator` joins the parts (", " on the Continue button). A
    /// book's percentage is in characters (`BookCharacters`); without them, just the volume.
    func continueLabel(
        isEpub: Bool, separator: String = " · ", characters: (KavitaChapter) -> BookProgress? = { _ in nil }
    ) -> String? {
        guard let chapter = continueChapter else { return nil }
        let place: String
        if let volume = volume(containing: chapter), volume.chapters.count == 1 || chapter.isWholeVolume {
            place = "Vol. \(volume.name)"
        } else if chapter.isSpecial {
            place = chapter.displayTitle(in: nil)
        } else {
            place = "Ch. \(chapter.range ?? chapter.number)"
        }
        guard chapter.pagesRead > 0, !chapter.isRead else { return place }
        if isEpub {
            return characters(chapter).map { place + separator + $0.percent } ?? place
        }
        return place + separator + "p. \(chapter.pagesRead + 1)"
    }
}
