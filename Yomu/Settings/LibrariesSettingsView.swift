import Core
import KavitaKit
import SwiftUI

/// Turns Kavita libraries on and off in the Library tab.
struct LibrariesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var libraries: [KavitaLibrary] = []
    @State private var loading = true

    var body: some View {
        Form {
            Section {
                if libraries.isEmpty {
                    if loading && environment.kavitaClient() != nil {
                        ProgressView()
                    } else {
                        Text("Sign in to Kavita to choose libraries.").foregroundStyle(.secondary)
                    }
                }
                ForEach(libraries) { library in
                    Toggle(isOn: binding(for: library)) {
                        Label(library.name, systemImage: library.isBookLibrary ? "book.closed" : "books.vertical")
                    }
                }
            } footer: {
                Text("Turned-off libraries are hidden from the Library tab and Continue Reading.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Libraries")
        .task {
            let repository = environment.kavitaLibrary
            libraries = ((try? repository.cachedLibraries()) ?? []).filter(LibraryModel.readable)
            // Straight after signing in nothing is saved yet: ask Kavita.
            if let client = environment.kavitaClient(), let fetched = try? await repository.refreshLibraries(using: client) {
                libraries = fetched.filter(LibraryModel.readable)
            }
            loading = false
        }
    }

    private func binding(for library: KavitaLibrary) -> Binding<Bool> {
        Binding {
            !environment.hiddenLibraries.contains(library.id)
        } set: { shown in
            try? environment.libraryVisibility.setHidden(library.id, hidden: !shown)
        }
    }
}
