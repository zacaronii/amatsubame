import AppCommon
import AudiobookshelfKit
import Core
import SwiftUI

/// Settings ▸ Downloads: cellular, plus download ahead for each podcast library.
struct KikuDownloadSettingsView: View {
    @Environment(KikuEnvironment.self) private var environment

    private var podcastLibraries: [AudiobookshelfLibrary] {
        let hidden = environment.library.hiddenLibraries
        return environment.library.libraries.filter { $0.mediaType == .podcast && !hidden.contains($0.id) }
    }

    var body: some View {
        Form {
            DownloadSettingsSection { _ in }
            if !podcastLibraries.isEmpty {
                Section {
                    ForEach(podcastLibraries) { library in
                        NavigationLink {
                            AudioAutoDownloadLibraryView(library: library)
                        } label: {
                            LabeledContent(library.name, value: AudioAutoDownloadText.summary(environment.autoDownloads.library(library.id)))
                        }
                        .accessibilityIdentifier("autoDownloads.library")
                    }
                } header: {
                    Text("Download Ahead")
                } footer: {
                    Text("Keeps the next episodes of shows you've played in the last 15 days downloaded. A show's page can turn it on or off for that show. Off unless you turn it on.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Downloads")
        .task { if environment.library.libraries.isEmpty { await environment.library.refreshLibraries() } }
    }
}

enum AudioAutoDownloadText {
    static let counts = [0, 1, 2, 3, 5, 10]

    static func episodes(_ count: Int) -> String {
        count == 0 ? "Off" : count == 1 ? "1 episode" : "\(count) episodes"
    }

    static func order(_ order: AudioAutoDownloadSetting.Order) -> String {
        switch order {
        case .newest: "Newest"
        case .inOrder: "In Order"
        }
    }

    static func summary(_ setting: AudioAutoDownloadSetting) -> String {
        setting.ahead == 0 ? "Off" : "\(setting.ahead) · \(order(setting.order))"
    }

    /// A show's state, under its title.
    static func status(_ coverage: AudioAutoDownloadPlanner.Coverage) -> String? {
        switch coverage {
        case .on(let rule): "Downloading ahead: \(episodes(rule.ahead).lowercased()), \(order(rule.order).lowercased())"
        case .paused: "Download ahead paused: not played in 15 days"
        case .off: nil
        }
    }
}

/// The count and order pickers, for a library or a show.
private struct AheadPickers: View {
    let setting: AudioAutoDownloadSetting
    var offLabel = "Off"
    let save: (AudioAutoDownloadSetting) -> Void

    var body: some View {
        Picker("Keep Downloaded", selection: Binding(get: { setting.ahead }, set: { value in
            var changed = setting
            changed.ahead = value
            save(changed)
        })) {
            ForEach(AudioAutoDownloadText.counts, id: \.self) { count in
                Text(count == 0 ? offLabel : AudioAutoDownloadText.episodes(count)).tag(count)
            }
        }
        .accessibilityIdentifier("autoDownloads.ahead")
        Picker("Order", selection: Binding(get: { setting.order }, set: { value in
            var changed = setting
            changed.order = value
            save(changed)
        })) {
            ForEach(AudioAutoDownloadSetting.Order.allCases, id: \.self) { Text(AudioAutoDownloadText.order($0)).tag($0) }
        }
        .accessibilityIdentifier("autoDownloads.order")
    }
}

struct AudioAutoDownloadLibraryView: View {
    @Environment(KikuEnvironment.self) private var environment
    let library: AudiobookshelfLibrary

    var body: some View {
        let setting = environment.autoDownloads.library(library.id)
        Form {
            Section {
                AheadPickers(setting: setting) { environment.autoDownloads.save($0) }
            } footer: {
                Text("For each show in \(library.name) you've played in the last 15 days. Newest keeps the latest episodes; In Order keeps the next ones after the episode you're on, for shows heard from the start.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(library.name)
    }
}

/// A show's own download ahead (from its page).
struct ShowAutoDownloadView: View {
    @Environment(KikuEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let show: AudiobookshelfItem

    enum Choice: Hashable { case library, on, off }

    var body: some View {
        let setting = environment.autoDownloads.show(show.id)
        let libraryRule = environment.autoDownloads.library(show.libraryId)
        NavigationStack {
            Form {
                Section {
                    Picker("Download Ahead", selection: Binding<Choice>(get: {
                        switch setting.isOn { case true?: .on; case false?: .off; case nil: .library }
                    }, set: { choice in
                        var changed = setting
                        changed.isOn = choice == .library ? nil : choice == .on
                        if choice != .on { changed.ahead = 0; changed.order = .newest }
                        environment.autoDownloads.save(changed)
                    })) {
                        Text("Library Setting (\(AudioAutoDownloadText.summary(libraryRule)))").tag(Choice.library)
                        Text("On").tag(Choice.on)
                        Text("Off").tag(Choice.off)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("showAutoDownloads.choice")
                } footer: {
                    if let status = AudioAutoDownloadText.status(environment.autoDownloads.coverage(of: show)) {
                        Text(status)
                    } else {
                        Text("Nothing downloads automatically for this show.")
                    }
                }
                if setting.isOn == true {
                    Section {
                        AheadPickers(setting: setting, offLabel: "As the Library (\(libraryRule.ahead == 0 ? 3 : libraryRule.ahead))") {
                            environment.autoDownloads.save($0)
                        }
                    } footer: {
                        Text("On keeps these downloaded even when you haven't played the show lately.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Download Ahead")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
