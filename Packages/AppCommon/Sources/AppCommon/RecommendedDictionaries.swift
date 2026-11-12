import Core
import Foundation

/// The recommended dictionaries: where to get each the first time.
/// After that, each one's own `index.json` says where its updates are.
public struct RecommendedDictionary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// One line on what it's for.
    public let purpose: String
    public let approximateBytes: Int
    public let downloadURL: URL
    /// Its licence, for About & Licenses.
    public let license: String
    /// Whether an installed dictionary (by title) is this one, e.g. one imported from Files.
    let matchesTitle: @Sendable (String) -> Bool

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public func matches(_ record: DictionaryRecord) -> Bool { matchesTitle(record.title) }
}

public enum RecommendedDictionaries {
    /// Installed in this order (Jitendex first: setup can continue once it's in).
    public static let all: [RecommendedDictionary] = [
        RecommendedDictionary(
            id: "jitendex", name: "Jitendex", purpose: "English definitions", approximateBytes: 38_800_000,
            downloadURL: URL(string: "https://github.com/stephenmk/stephenmk.github.io/releases/latest/download/jitendex-yomitan.zip")!,
            license: "Jitendex by Stephen Kraus, CC BY-SA 4.0, built from JMdict (EDRDG licence).",
            matchesTitle: { $0.hasPrefix("Jitendex") }),
        RecommendedDictionary(
            id: "jmnedict", name: "JMnedict", purpose: "Names of people and places", approximateBytes: 11_400_000,
            downloadURL: URL(string: "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/JMnedict.zip")!,
            license: "JMnedict, © the Electronic Dictionary Research and Development Group, CC BY-SA 4.0.",
            matchesTitle: { $0.hasPrefix("JMnedict") }),
        RecommendedDictionary(
            id: "kanjidic", name: "KANJIDIC", purpose: "Kanji meanings and readings", approximateBytes: 720_000,
            downloadURL: URL(string: "https://github.com/yomidevs/jmdict-yomitan/releases/latest/download/KANJIDIC_english.zip")!,
            license: "KANJIDIC2, © the Electronic Dictionary Research and Development Group, CC BY-SA 4.0.",
            matchesTitle: { $0.hasPrefix("KANJIDIC") }),
        RecommendedDictionary(
            id: "jiten", name: "Jiten Frequency", purpose: "How common each word is in anime, novels and games",
            approximateBytes: 8_000_000,
            downloadURL: URL(string: "https://api.jiten.moe/api/frequency-list/download?downloadType=yomitan")!,
            license: "Jiten frequency lists from jiten.moe, CC BY-SA 4.0.",
            matchesTitle: { $0 == "Jiten" || $0.hasPrefix("Jiten ") && !$0.hasPrefix("Jiten (") }),
        RecommendedDictionary(
            id: "kanjium", name: "Kanjium", purpose: "Pitch accent", approximateBytes: 1_100_000,
            downloadURL: URL(string: "https://github.com/toasted-nutbread/yomichan-pitch-accent-dictionary/releases/latest/download/kanjium_pitch_accents.zip")!,
            license: "Kanjium pitch accents by Uros Ozvatic (github.com/mifunetoshiro/kanjium), packaged by toasted-nutbread.",
            matchesTitle: { $0.hasPrefix("Kanjium") }),
    ]

    /// Setup can continue once this one is in.
    public static let required = "jitendex"
    /// Sorts results when no frequency dictionary is chosen.
    public static let frequency = "jiten"

    public static func entry(_ id: String) -> RecommendedDictionary? { all.first { $0.id == id } }

    /// The recommended entry an installed dictionary is: by where it came from, else by title.
    public static func entry(for record: DictionaryRecord, source: DictionarySource?) -> RecommendedDictionary? {
        source?.catalogId.flatMap(entry) ?? all.first { $0.matches(record) }
    }
}
