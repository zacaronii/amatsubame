@testable import AppCommon
import Foundation
import Testing

/// About's feedback links open the repository's issue forms with what the app knows filled in.
@MainActor @Suite struct FeedbackTests {
    private func items(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func aBugReportFillsInTheAppVersionAndDevice() {
        let url = Feedback.url(.bug, app: "Miru", version: "0.4.0 (202611260000)", device: "iPhone18,2 · iOS 26.5")
        #expect(url.absoluteString.hasPrefix("https://github.com/zacaronii/amatsubame/issues/new?"))
        let query = items(url)
        #expect(query["template"] == "bug.yml")
        #expect(query["title"] == "Bug: Miru – ")
        #expect(query["app"] == "Miru")
        #expect(query["version"] == "0.4.0 (202611260000)")
        #expect(query["device"] == "iPhone18,2 · iOS 26.5")
    }

    @Test func anIdeaOnlyNamesTheApp() {
        let query = items(Feedback.url(.idea, app: "Kiku", version: "0.4.0 (1)", device: "Mac15,3 · macOS 26.1"))
        #expect(query["template"] == "feature.yml")
        #expect(query["title"] == "FR: Kiku – ")
        #expect(query["app"] == "Kiku")
        #expect(query["version"] == nil && query["device"] == nil)
    }

    @Test func theDeviceNamesAModelAndASystem() {
        #expect(Feedback.device.contains(" · "))
    }
}
