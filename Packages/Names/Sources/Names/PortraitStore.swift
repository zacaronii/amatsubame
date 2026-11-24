import Core
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Characters' portraits, kept small (at most 150 px tall, JPEG: about 7 KB each) in a folder
/// beside the dictionaries, so a cast opened again needs no network.
public struct PortraitStore: Sendable {
    public static let maxPixels = 150
    public let directory: URL
    let http: HTTPClient

    public init(directory: URL, http: HTTPClient) {
        self.directory = directory
        self.http = http
    }

    /// The portrait for a character: kept, else fetched and kept. Nil when it can't be had.
    public func portrait(for character: AniListCharacter) async -> NameDictionaryCast.Portrait? {
        let file = directory.appending(path: "\(character.id).jpg")
        if let kept = Self.size(of: file) { return NameDictionaryCast.Portrait(file: file, width: kept.width, height: kept.height) }
        guard let url = character.image else { return nil }
        var request = URLRequest(url: url)
        request.setValue(RequestLimiter.userAgent, forHTTPHeaderField: "User-Agent")
        guard let response = try? await http.send(request), let small = Self.shrink(response.data) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? small.data.write(to: file, options: .atomic)) != nil else { return nil }
        return NameDictionaryCast.Portrait(file: file, width: small.width, height: small.height)
    }

    /// Removes portraits no kept cast uses.
    public func prune(keeping ids: Set<Int>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.hasSuffix(".jpg") {
            guard let id = Int(name.dropLast(4)), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// The image re-encoded as a JPEG at most `maxPixels` on its longer side.
    static func shrink(_ data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width, image.height)
    }

    static func size(of file: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
