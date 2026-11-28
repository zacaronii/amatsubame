import Core
import CoreText
import Foundation

/// Fonts the reader added for books: their files in a folder of this device's container, their
/// records in `BookFontStore`. A file is kept only if the system can register it as a font
/// (parsing isn't enough), within `BookFont.maxCount` and `BookFont.maxBytes`.
public struct BookFontLibrary: Sendable {
    public let folder: URL
    public let store: BookFontStore

    public init(folder: URL, store: BookFontStore) {
        self.folder = folder.standardizedFileURL
        self.store = store
    }

    public enum ImportError: LocalizedError, Equatable {
        case notAFont, tooLarge, tooMany
        public var errorDescription: String? {
            switch self {
            case .notAFont: "That file isn't a font Yomu can use."
            case .tooLarge: "That font is larger than 50 MB."
            case .tooMany: "Yomu keeps up to \(BookFont.maxCount) fonts. Remove one first."
            }
        }
    }

    static let extensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]

    /// Copies a font file in, named from the font itself.
    @discardableResult
    public func add(_ source: URL, now: Date = .now) throws -> BookFont {
        guard try store.fonts().count < BookFont.maxCount else { throw ImportError.tooMany }
        let ext = source.pathExtension.lowercased()
        guard Self.extensions.contains(ext) else { throw ImportError.notAFont }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw ImportError.notAFont }
        guard size <= BookFont.maxBytes else { throw ImportError.tooLarge }
        guard let name = Self.registrableName(source) else { throw ImportError.notAFont }
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(id).\(ext)")
        try FileManager.default.copyItem(at: source, to: file)
        let font = BookFont(id: id, name: name, fileName: file.lastPathComponent, addedAt: now)
        do { try store.add(font) } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return font
    }

    public func remove(_ id: String) throws {
        if let font = try store.font(id: id) {
            try? FileManager.default.removeItem(at: folder.appending(path: font.fileName))
        }
        try store.remove(id)
    }

    /// The file for a font the pages ask for: only an id the store knows, only in the folder.
    public func file(id: String) -> URL? {
        // The stored name is one plain file name (it was made here: "<id>.<ext>"), looked up in
        // the folder: no slashes or dot names, so nothing outside it.
        guard let font = try? store.font(id: id), !font.fileName.contains("/"), !font.fileName.hasPrefix(".") else { return nil }
        let file = folder.appending(path: font.fileName)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        return file
    }

    /// The font's family name, if the system can read it and register it (then unregistered:
    /// the book page loads it itself).
    static func registrableName(_ url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            // Already registered (the same file added twice), or a font of the same name as one
            // the system has (your own copy of it): still usable, as the page loads it itself.
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            guard code == CTFontManagerError.alreadyRegistered.rawValue || code == CTFontManagerError.duplicatedName.rawValue else { return nil }
            return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String ?? url.deletingPathExtension().lastPathComponent
        }
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
        let name = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
        return name?.isEmpty == false ? name : url.deletingPathExtension().lastPathComponent
    }
}
