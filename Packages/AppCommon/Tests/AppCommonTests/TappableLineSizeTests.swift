@testable import AppCommon
import SwiftUI
import Testing

/// Transcript text follows the system text size like body text; subtitles over video don't.
@MainActor @Suite struct TappableLineSizeTests {
    @Test func transcriptsScaleWithTheTextSize() {
        #expect(TappableLine.scaledFontSize(20, for: .large, style: .plain) == 20)
        #expect(TappableLine.scaledFontSize(20, for: .xSmall, style: .plain) == 16)
        #expect(TappableLine.scaledFontSize(19, for: .xxxLarge, style: .plain) == 26)
        #expect(TappableLine.scaledFontSize(24, for: .accessibility5, style: .plain) == 75)
    }

    @Test func subtitlesOverVideoKeepTheirSize() {
        #expect(TappableLine.scaledFontSize(30, for: .accessibility5, style: .overlay) == 30)
        #expect(TappableLine.scaledFontSize(30, for: .xSmall, style: .overlay) == 30)
    }
}
