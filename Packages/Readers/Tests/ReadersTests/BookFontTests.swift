import Core
import Foundation
@testable import Readers
import Testing

/// Added fonts, with a system font copied in at test time (no font is in the repository).
@Suite struct BookFontTests {
    let temp = FileManager.default.temporaryDirectory.appending(path: "BookFontTests-\(UUID().uuidString)")

    func library() throws -> BookFontLibrary {
        BookFontLibrary(folder: temp.appending(path: "Fonts"), store: BookFontStore(database: try AppDatabase.inMemory()))
    }

    /// A font the system has, copied to a temp file (a different system's set may vary).
    func systemFont() throws -> URL {
        let candidates = ["/System/Library/Fonts/Supplemental/Georgia.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf",
                          "/System/Library/Fonts/Supplemental/Times New Roman.ttf"]
        let source = try #require(candidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(filePath: $0) })
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let copy = temp.appending(path: "\(UUID().uuidString).ttf")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    @Test func aFontIsAddedUnderItsOwnName() throws {
        let fonts = try library()
        let font = try fonts.add(try systemFont())
        #expect(!font.name.isEmpty && !font.name.contains(".ttf"), "named from the font: \(font.name)")
        #expect(fonts.file(id: font.id) != nil)
        try fonts.remove(font.id)
        #expect(fonts.file(id: font.id) == nil)
        #expect(try fonts.store.fonts().isEmpty)
    }

    @Test func aFileThatIsNotAFontIsRefused() throws {
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let fake = temp.appending(path: "fake.ttf")
        try Data("not a font".utf8).write(to: fake)
        #expect(throws: BookFontLibrary.ImportError.notAFont) { try library().add(fake) }
        let text = temp.appending(path: "notes.txt")
        try Data("text".utf8).write(to: text)
        #expect(throws: BookFontLibrary.ImportError.notAFont) { try library().add(text) }
    }

    @Test func twentyFontsAtMost() throws {
        let fonts = try library()
        for index in 0..<BookFont.maxCount {
            try fonts.store.add(BookFont(id: UUID().uuidString, name: "F\(index)", fileName: "x.ttf", addedAt: .now))
        }
        #expect(throws: BookFontLibrary.ImportError.tooMany) { try fonts.add(try systemFont()) }
    }

    /// The pages get a font only by an id the library knows: no paths, no other files.
    @Test func theSchemeServesOnlyKnownFontIDs() throws {
        let fonts = try library()
        let font = try fonts.add(try systemFont())
        let book = temp.appending(path: "Book")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let handler = BookSchemeHandler(folder: book, fonts: fonts)
        #expect(handler.file(for: try #require(BookSchemeHandler.fontURL(id: font.id))) == fonts.file(id: font.id))
        for attempt in ["kavitabook://fonts/../Fonts/\(font.fileName)", "kavitabook://fonts/\(font.id)/x",
                        "kavitabook://fonts/%2E%2E", "kavitabook://fonts/\(UUID().uuidString)", "kavitabook://fonts/"] {
            #expect(handler.file(for: try #require(URL(string: attempt))) == nil, "\(attempt)")
        }
        #expect(BookSchemeHandler.fontURL(id: "../x") == nil)
        #expect(BookSchemeHandler(folder: book).file(for: try #require(BookSchemeHandler.fontURL(id: font.id))) == nil, "no library: no fonts")
    }
}
