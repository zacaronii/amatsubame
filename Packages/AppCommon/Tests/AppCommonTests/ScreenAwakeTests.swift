import Testing
@testable import AppCommon

/// The screen stays on while any reason holds (reading, read-along's audio), not just the last one set.
@MainActor struct ScreenAwakeTests {
    @Test func staysOnUntilEveryReasonIsGone() {
        ScreenAwake.set(true, reason: "reading")
        ScreenAwake.set(true)
        ScreenAwake.set(false)
        #expect(ScreenAwake.isKeepingAwake, "read-along paused, still reading")
        ScreenAwake.set(false, reason: "reading")
        #expect(!ScreenAwake.isKeepingAwake)
    }
}
