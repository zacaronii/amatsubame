import Core
import CoreGraphics
import CoreTestSupport
import Foundation
import ImageIO
@testable import Names
import UniformTypeIdentifiers

/// JMnedict's readings for the made-up names.
struct FakeReadings: NameReadingSource {
    var known: [String: [String]] = ["架空": ["かくう", "かそら"], "太郎": ["たろう"], "夢見": ["ゆめみ"], "大石": ["おおいし"], "灰原": ["はいばら"]]
    func readings(of expression: String) async -> [String] { known[expression] ?? [] }
}

enum NamesFixtures {
    static func data(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    /// A small PNG, as AniList's portraits are.
    static func png(width: Int = 100, height: Int = 150) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// AniList and MangaBaka as the fixtures have them: GraphQL by what the query asks for.
    static func transport(mangaBaka: Data? = nil) throws -> StubTransport {
        let cast = try data("anilist-cast.json"), searchData = try data("anilist-search.json")
        let match = try mangaBaka ?? data("mangabaka-match.json"), image = png()
        return StubTransport { request in
            switch request.url?.host() {
            case "img.example": return (200, image)
            case "api.mangabaka.org": return (200, match)
            default:
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                if body.contains("characters(") { return (200, cast) }
                if body.contains("Page(") { return (200, searchData) }
                if body.contains("idMal:") {
                    let media = #"{"data":{"Media":{"id":900001,"type":"MANGA","format":"MANGA","title":{"native":"架空の物語"}}}}"#
                    return (200, Data(media.utf8))
                }
                return (404, Data())
            }
        }
    }
}
