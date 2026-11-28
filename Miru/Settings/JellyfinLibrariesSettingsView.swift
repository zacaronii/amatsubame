import Core
import JellyfinKit
import SwiftUI

/// Turns Jellyfin libraries on and off in the Watch tab.
struct JellyfinLibrariesSettingsView: View {
    @Environment(PlayerEnvironment.self) private var environment
    @State private var libraries: [JellyfinItem] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        Form {
            Section {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if libraries.isEmpty && environment.jellyfinClient() == nil {
                    Text("Sign in to Jellyfin to choose libraries.").foregroundStyle(.secondary)
                } else if libraries.isEmpty && loading {
                    ProgressView()
                }
                ForEach(libraries) { library in
                    Toggle(isOn: binding(for: library)) {
                        Label(library.name, systemImage: library.collectionType == "movies" ? "film" : "tv")
                    }
                }
            } footer: {
                Text("Turned-off libraries are hidden from the Watch tab.")
            }
            JapaneseAudioOnlySection()
        }
        .formStyle(.grouped)
        .navigationTitle("Libraries")
        .task {
            guard let client = environment.jellyfinClient() else { return }
            defer { loading = false }
            do {
                libraries = try await client.views()
            } catch {
                guard !error.isCancellation else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func binding(for library: JellyfinItem) -> Binding<Bool> {
        Binding {
            !environment.hiddenLibraries.contains(library.id)
        } set: { shown in
            try? environment.libraryVisibility.setHidden(library.id, hidden: !shown)
        }
    }
}

/// Settings ▸ Watching ▸ Playback: per library, show only items with a Japanese audio track.
struct JapaneseAudioOnlySection: View {
    @Environment(PlayerEnvironment.self) private var environment
    @State private var libraries: [JellyfinItem] = []

    var body: some View {
        Section {
            if libraries.isEmpty {
                Text(environment.jellyfinClient() == nil ? "Sign in to Jellyfin to choose libraries."
                     : state == .loading ? "Loading libraries…"
                     : state == .failed ? "Couldn\u{2019}t reach Jellyfin." : "No libraries are shown in Miru.")
                    .foregroundStyle(.secondary)
            }
            ForEach(libraries) { library in
                Toggle(library.name, isOn: Binding {
                    environment.japaneseOnlyLibraries.contains(library.id)
                } set: { on in
                    try? environment.libraryVisibility.setJapaneseOnly(library.id, on)
                })
                .accessibilityIdentifier("libraries.japaneseOnly.\(library.name)")
            }
        } header: {
            Text("Japanese Audio Only")
        } footer: {
            Text("Hides titles without Japanese audio (untagged audio doesn't count; a show goes by its first episode). Episodes with several audio tracks start on the Japanese one.")
        }
        .task {
            guard let client = environment.jellyfinClient() else { return }
            guard let views = try? await client.views() else {
                state = .failed
                return
            }
            libraries = views.filter { !environment.hiddenLibraries.contains($0.id) }
            state = .loaded
        }
    }

    private enum LoadState { case loading, loaded, failed }
    @State private var state = LoadState.loading
}
