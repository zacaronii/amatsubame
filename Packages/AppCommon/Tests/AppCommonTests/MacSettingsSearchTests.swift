#if os(macOS)
@testable import AppCommon
import SwiftUI
import Testing

/// The Mac Settings sidebar's search: a page shows when its title or one of its row titles matches.
@MainActor
@Suite struct MacSettingsSearchTests {
    let groups = [
        MacSettingsGroup("Lookup", pages: [
            MacSettingsPage("popup", title: "Popup", systemImage: "text.bubble", keywords: ["Background Opacity", "Look Up on Hover"]) { EmptyView() },
            MacSettingsPage("wordMarks", title: "Word Marks", systemImage: "underline") { EmptyView() },
        ]),
        MacSettingsGroup(pages: [
            MacSettingsPage("advanced", title: "Advanced", systemImage: "wrench", keywords: ["Export Logs"]) { EmptyView() },
        ]),
    ]

    @Test func findsPagesByTheirRowTitles() {
        let shown = MacSettingsWindow.filter(groups, search: "opacity")
        #expect(shown.map(\.title) == ["Lookup"])
        #expect(shown.first?.pages.map(\.id) == ["popup"])
        #expect(MacSettingsWindow.filter(groups, search: " logs ").flatMap(\.pages).map(\.id) == ["advanced"])
    }

    @Test func stillFindsPagesByTitleAndShowsAllWhenEmpty() {
        #expect(MacSettingsWindow.filter(groups, search: "marks").flatMap(\.pages).map(\.id) == ["wordMarks"])
        #expect(MacSettingsWindow.filter(groups, search: "").flatMap(\.pages).count == 3)
        #expect(MacSettingsWindow.filter(groups, search: "nothing like this").isEmpty)
    }
}
#endif
