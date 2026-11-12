import SwiftUI

/// The iPad's (and Mac's) sidebar lists the libraries under the tabs (`.tabViewSidebarFooter`),
/// opening each in the app's library tab. Not tabs of their own: picked, a tab section joins the
/// iPad's top bar.
public struct SidebarLibraries<Library: Identifiable>: View {
    let libraries: [Library]
    let name: (Library) -> String
    let systemImage: (Library) -> String
    let open: (Library) -> Void

    public init(_ libraries: [Library], name: @escaping (Library) -> String, systemImage: @escaping (Library) -> String,
                open: @escaping (Library) -> Void) {
        self.libraries = libraries
        self.name = name
        self.systemImage = systemImage
        self.open = open
    }

    public var body: some View {
        if !libraries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Libraries").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                ForEach(libraries) { library in
                    Button {
                        open(library)
                    } label: {
                        Label(name(library), systemImage: systemImage(library))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.library")
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
