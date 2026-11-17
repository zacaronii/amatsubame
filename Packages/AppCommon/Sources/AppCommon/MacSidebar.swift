#if os(macOS)
import SwiftUI

/// Where the Mac's sidebar can go: an app's main destination, what's downloaded, or one library.
public enum SidebarDestination<Tab: Hashable, Library: Hashable>: Hashable {
    case tab(Tab)
    case downloaded
    case library(Library)
}

/// A row in the Mac's sidebar.
public struct SidebarRow<ID: Hashable>: Identifiable {
    public let id: ID
    let title: String
    let systemImage: String
    let count: Int?

    public init(_ id: ID, title: String, systemImage: String, count: Int? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count
    }
}

/// The Mac's main window: a sidebar of the app's main destinations, On This Mac ▸ Downloaded and
/// the libraries, each opening its own screen. iPhone and iPad keep the system `TabView`.
///
/// Not `TabView(.sidebarAdaptable)`: on the Mac it shares one navigation column between the
/// tabs, and once another tab had shown, a path the code set crashed (`comparisonTypeMismatch`)
/// or was ignored. Here each destination is its own stack, made afresh when it's chosen.
public struct MacSidebarSplit<Tab: Hashable, Library: Hashable, Detail: View>: View {
    public typealias Destination = SidebarDestination<Tab, Library>

    @Binding var selection: Destination
    let main: [SidebarRow<Destination>]
    let downloaded: SidebarRow<Destination>?
    let libraries: [SidebarRow<Destination>]
    let detail: (Destination) -> Detail
    /// Bumped when the chosen row is clicked again: its screen starts over.
    @State private var resets: [Destination: Int] = [:]
    @SceneStorage("sidebar.shown") private var sidebarShown = true

    public init(selection: Binding<Destination>, main: [SidebarRow<Destination>], downloaded: SidebarRow<Destination>?,
                libraries: [SidebarRow<Destination>], @ViewBuilder detail: @escaping (Destination) -> Detail) {
        _selection = selection
        self.main = main
        self.downloaded = downloaded
        self.libraries = libraries
        self.detail = detail
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { sidebarShown ? .all : .detailOnly },
                                                      set: { sidebarShown = $0 != .detailOnly })) {
            List(selection: Binding<Destination?>(get: { selection }, set: { if let new = $0 { selection = new } })) {
                Section {
                    ForEach(main) { row($0) }
                }
                if let downloaded {
                    Section("On This Mac") { row(downloaded) }
                }
                if !libraries.isEmpty {
                    Section("Libraries") {
                        ForEach(libraries) { row($0) }
                    }
                }
            }
            // Wide enough for a library name like オーディオブック.
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
        } detail: {
            detail(selection)
                .id(DetailKey(destination: selection, reset: resets[selection, default: 0]))
        }
    }

    private func row(_ row: SidebarRow<Destination>) -> some View {
        Label {
            HStack {
                Text(row.title).lineLimit(1)
                Spacer()
                if let count = row.count, count > 0 {
                    Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: row.systemImage)
        }
        .tag(row.id)
        // Clicked while it's the one showing: back to its start (a list doesn't report that).
        .simultaneousGesture(TapGesture().onEnded {
            if selection == row.id { resets[row.id, default: 0] += 1 }
        })
        .accessibilityIdentifier("sidebar.row")
    }

    private struct DetailKey: Hashable {
        let destination: Destination
        let reset: Int
    }
}
#endif
