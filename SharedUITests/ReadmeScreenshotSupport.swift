import XCTest

/// The README's screenshots (docs/media/CREDITS.md, `scripts/readme-screenshots.sh`): the whole
/// screen, status bar included, kept as an attachment that the script exports from the result.
/// Names: `readme-1-home` (the library or home with the demo content) and `readme-2-lookup` (the
/// popup open on a word).
extension XCTestCase {
    func readmeScreenshot(_ name: String, settle seconds: UInt32 = 2) {
        sleep(seconds)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
