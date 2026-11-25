@testable import AppCommon
import Foundation
import Testing

/// The data services' credits link to their site and terms, as their terms ask
/// (MangaBaka's CC BY-NC-SA: a link to the licence).
@MainActor @Suite struct AboutCreditsTests {
    @Test func theDataServicesAreCreditedWithLinks() {
        let names = AboutView.shared.map(\.0)
        #expect(Set(AboutView.creditLinks.keys) == ["AniList", "MangaBaka"])
        #expect(AboutView.creditLinks.keys.allSatisfy(names.contains))
        #expect(AboutView.creditLinks["MangaBaka"]?.license.absoluteString == "https://creativecommons.org/licenses/by-nc-sa/4.0/")
    }

    #if os(macOS)
    @Test func theMacAboutPanelLinksThemToo() {
        let text = AboutView.creditsText(appCredits: [])
        var links: [URL] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.contains(URL(string: "https://mangabaka.org")!))
        #expect(links.contains(URL(string: "https://creativecommons.org/licenses/by-nc-sa/4.0/")!))
        #expect(links.contains(URL(string: "https://docs.anilist.co/guide/terms-of-use")!))
    }
    #endif
}
