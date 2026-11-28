import CryptoKit
import Dictionary
import Foundation
import ZIPFoundation

/// A cast to put in the names dictionary: the series it's from and its characters' spellings.
public struct NameDictionaryCast: Sendable {
    public struct Character: Sendable {
        public var character: AniListCharacter
        public var forms: [NameForm]
        /// The portrait's file in the dictionary (`img/<id>.jpg`) and its size, when there is one.
        public var portrait: Portrait?

        public init(character: AniListCharacter, forms: [NameForm], portrait: Portrait? = nil) {
            self.character = character
            self.forms = forms
            self.portrait = portrait
        }
    }

    public struct Portrait: Sendable {
        public var file: URL
        public var width: Int
        public var height: Int

        public init(file: URL, width: Int, height: Int) {
            self.file = file
            self.width = width
            self.height = height
        }
    }

    public var title: String
    public var characters: [Character]

    public init(title: String, characters: [Character]) {
        self.title = title
        self.characters = characters
    }
}

/// Writes the names dictionary: a Yomitan (format 3) zip with one entry per spelling, each with
/// the character's portrait, romaji name, role and series. Its revision is a hash of what's in
/// it, so the same casts again aren't installed again.
public enum NameDictionaryBuilder {
    public static let title = NameRanking.characterNamesTitle

    public static func write(_ casts: [NameDictionaryCast], to zip: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: zip)
        var rows: [[Any]] = []
        var images: [(path: String, file: URL)] = []
        var imagePaths = Set<String>()
        for cast in casts {
            for entry in cast.characters {
                let character = entry.character
                var imagePath: String?
                if let portrait = entry.portrait {
                    let path = "img/\(character.id).jpg"
                    imagePath = path
                    if imagePaths.insert(path).inserted { images.append((path, portrait.file)) }
                }
                for form in entry.forms {
                    let tags = ["name", character.role == .main ? "main" : "supporting"].joined(separator: " ")
                    rows.append([
                        form.term, form.reading ?? "", tags, "", character.role == .main ? 2 : 1,
                        [card(character, form: form, series: cast.title, image: imagePath, portrait: entry.portrait)],
                        character.id, "",
                    ])
                }
            }
        }
        let terms = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])
        let tags = try JSONSerialization.data(withJSONObject: [
            ["name", "name", 0, "Character name", 0],
            ["main", "name", 0, "Main character", 0],
            ["supporting", "name", 0, "Supporting character", 0],
        ])
        var hash = SHA256()
        hash.update(data: terms)
        for image in images { hash.update(data: Data(image.path.utf8)) }
        let revision = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let index = try JSONSerialization.data(withJSONObject: [
            "title": title, "format": 3, "revision": revision, "author": "Amatsubame",
            "description": "The casts of the series open in Yomu and Miru.",
            "attribution": "Character names and pictures from AniList (anilist.co).",
        ] as [String: Any], options: .sortedKeys)

        let archive = try Archive(url: zip, accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        try add("index.json", index)
        try add("tag_bank_1.json", tags)
        try add("term_bank_1.json", terms)
        for image in images {
            guard let data = try? Data(contentsOf: image.file) else { continue }
            try add(image.path, data)
        }
    }

    /// The glossary: portrait beside the name, its romaji, and who they are.
    static func card(_ character: AniListCharacter, form: NameForm, series: String, image: String?,
                     portrait: NameDictionaryCast.Portrait?) -> [String: Any] {
        let name = character.native?.trimmingCharacters(in: .whitespaces) ?? form.term
        var details: [Any] = [["tag": "div", "style": ["fontWeight": "bold"], "content": name]]
        if let full = character.full, !full.isEmpty { details.append(["tag": "div", "content": full]) }
        let role = character.role == .main ? "Main character" : "Supporting character"
        let part: String? = switch form.part {
        case .family: "Family name"
        case .given: "Given name"
        case .part: "Part of the name"
        case .alias: "Also called"
        case .full: nil
        }
        details.append(["tag": "div", "style": ["fontSize": "0.85em"], "content": ([part, role].compactMap(\.self).joined(separator: " · ")) + " in " + series])
        var content: [Any] = []
        if let image, let portrait {
            content.append(["tag": "img", "path": image, "width": portrait.width, "height": portrait.height,
                            "preferredWidth": 64, "sizeUnits": "px", "collapsible": false, "background": false,
                            "title": name])
        }
        content.append(["tag": "div", "content": details])
        return ["type": "structured-content", "content": [
            "tag": "div", "data": ["names": "card"], "style": ["marginBottom": "0.25em"], "content": content,
        ] as [String: Any]]
    }
}
