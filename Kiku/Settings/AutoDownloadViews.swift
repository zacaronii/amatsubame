import AppCommon
import AudiobookshelfKit
import Core
import KikuWatchLink
import SwiftUI

/// Settings ▸ Downloads: cellular, plus automatic downloads for each library shown.
struct KikuDownloadSettingsView: View {
    @Environment(KikuEnvironment.self) private var environment

    private var libraries: [AudiobookshelfLibrary] {
        let hidden = environment.library.hiddenLibraries
        return environment.library.libraries.filter { !hidden.contains($0.id) }
    }

    var body: some View {
        Form {
            DownloadSettingsSection { _ in }
            if !libraries.isEmpty {
                Section {
                    ForEach(libraries) { library in
                        NavigationLink {
                            AudioAutoDownloadLibraryView(library: library)
                        } label: {
                            LabeledContent(library.name, value: AudioAutoDownloadText.summary(environment.autoDownloads.library(library.id)))
                        }
                        .accessibilityIdentifier("autoDownloads.library")
                    }
                } header: {
                    Text("Automatic Downloads")
                } footer: {
                    Text("Download ahead keeps the next episodes of shows you've played lately; Download Once Started keeps what you start playing. Off for every library unless you turn it on.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Download Rules")
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
        var parts: [String] = []
        if setting.ahead > 0 { parts.append("\(setting.ahead) ahead · \(order(setting.order))") }
        if setting.onceStarted { parts.append("once started") }
        if setting.removesPlayed { parts.append("removes played") }
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
    }

    /// A library's or show's download ahead alone ("Off", "3 · Newest").
    static func ahead(_ setting: AudioAutoDownloadSetting) -> String {
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
            if library.mediaType == .podcast {
                Section {
                    AheadPickers(setting: setting) { environment.autoDownloads.save($0) }
                } header: {
                    Text("Download Ahead")
                } footer: {
                    Text("For each show in \(library.name) you've played in the last 15 days. Newest keeps the latest episodes; In Order keeps the next ones after the episode you're on, for shows heard from the start.")
                }
            }
            Section {
                Toggle("Download Once Started", isOn: Binding(get: { setting.onceStarted }, set: { value in
                    var changed = setting
                    changed.onceStarted = value
                    environment.autoDownloads.save(changed)
                }))
                .accessibilityIdentifier("autoDownloads.onceStarted")
            } footer: {
                Text(library.mediaType == .podcast
                     ? "An episode you start playing downloads while you listen; next time it plays from the device, even offline."
                     : "A book you start playing downloads while you listen; next time it plays from the device, even offline.")
            }
            Section {
                Toggle("Remove Played Downloads", isOn: Binding(get: { setting.removesPlayed }, set: { value in
                    var changed = setting
                    changed.removesPlayed = value
                    environment.autoDownloads.save(changed)
                }))
                .accessibilityIdentifier("autoDownloads.removePlayed")
                if setting.removesPlayed {
                    Toggle("Keep Downloads You Made by Hand", isOn: Binding(get: { setting.keepsManual }, set: { value in
                        var changed = setting
                        changed.keepsManual = value
                        environment.autoDownloads.save(changed)
                    }))
                    .accessibilityIdentifier("autoDownloads.keepManual")
                }
            } footer: {
                Text(setting.removesPlayed && setting.keepsManual
                     ? "A day after you finish \(library.mediaType == .podcast ? "an episode" : "a book"), its automatic download is removed. Ones you downloaded yourself stay."
                     : "A day after you finish \(library.mediaType == .podcast ? "an episode" : "a book"), its download is removed\(setting.removesPlayed ? ", including ones you downloaded yourself" : ""). Never what's playing.")
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
                        Text("Library Setting (\(AudioAutoDownloadText.ahead(libraryRule)))").tag(Choice.library)
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
                ShowPlaybackSection(itemId: show.id)
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

/// A show's own playback: seconds to skip at the start and end of every episode (its jingle, its
/// sign-off), and whether it keeps a speed of its own (the player's speed menu sets which).
struct ShowPlaybackSection: View {
    @Environment(KikuEnvironment.self) private var environment
    let itemId: String
    @State private var setting = ShowListenSetting(itemId: "")

    var body: some View {
        Section {
            Picker("Skip the First", selection: binding(\.skipStart)) {
                ForEach(ShowListenSetting.skipChoices, id: \.self) { Text($0 == 0 ? "Nothing" : "\(Int($0)) seconds").tag($0) }
            }
            .accessibilityIdentifier("show.skipStart")
            Picker("Skip the Last", selection: binding(\.skipEnd)) {
                ForEach(ShowListenSetting.skipChoices, id: \.self) { Text($0 == 0 ? "Nothing" : "\(Int($0)) seconds").tag($0) }
            }
            .accessibilityIdentifier("show.skipEnd")
            if let speed = setting.speed {
                LabeledContent("Speed") {
                    Button("\(PlayerView.speedText(speed)) · Use the Usual Speed") {
                        setting.speed = nil
                        try? setting.save(environment.common.database)
                    }
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("For a jingle at the start and the sign-off at the end of every episode. An episode you play from the beginning starts after the first; it counts as finished when the last begins. A speed for this show alone is set from the player's speed menu.")
        }
        .onAppear { setting = ShowListenSetting.load(environment.common.database, itemId: itemId) }
    }

    private func binding(_ keyPath: WritableKeyPath<ShowListenSetting, Double>) -> Binding<Double> {
        Binding(get: { setting[keyPath: keyPath] }, set: { value in
            setting[keyPath: keyPath] = value
            try? setting.save(environment.common.database)
        })
    }
}

#if os(iOS)
/// Apple Watch's automatic rules (docs/KIKU_PLAN.md milestone 4), built from the lists above.
struct WatchRulesSection: View {
    @Environment(KikuEnvironment.self) private var environment

    var body: some View {
        let library = environment.watchLibrary
        if library.isWatchAppInstalled {
            let rules = library.rules
            Section {
                Toggle("Sync Once Started", isOn: binding(\.onceStarted))
                    .accessibilityIdentifier("watchRules.onceStarted")
                Picker("Download Ahead", selection: binding(\.ahead)) {
                    ForEach(KikuWatchRules.aheadChoices, id: \.self) { count in
                        Text(count == 0 ? "Off" : count == 1 ? "First episode" : "First \(count)").tag(count)
                    }
                }
                .accessibilityIdentifier("watchRules.ahead")
                Toggle("Remove Played", isOn: binding(\.removesPlayed))
                if rules.removesPlayed {
                    Toggle("Keep Items You Sent by Hand", isOn: binding(\.keepsManual))
                }
                Picker("Storage Limit", selection: binding(\.storageLimit)) {
                    ForEach(KikuWatchRules.storageChoices, id: \.self) { bytes in
                        Text(bytes == 0 ? "None" : WatchItemStatus.size(bytes)).tag(bytes)
                    }
                }
            } header: {
                Text("Apple Watch")
            } footer: {
                Text(footer(library))
            }
        }
    }

    private func footer(_ library: WatchLibraryModel) -> String {
        var parts = ["Sync Once Started sends what you start playing on this iPhone to your watch too. Download Ahead keeps the first episodes of each show's download ahead (set above) on the watch. Remove Played takes an episode or book off the watch a day after it's finished. The limit stops the rules, not what you send yourself. An item a rule added that you remove stays off."]
        if let message = library.rulesMessage { parts.append(message) }
        return parts.joined(separator: " ")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<KikuWatchRules, Value>) -> Binding<Value> {
        Binding {
            environment.watchLibrary.rules[keyPath: keyPath]
        } set: { value in
            var rules = environment.watchLibrary.rules
            rules[keyPath: keyPath] = value
            environment.watchLibrary.save(rules)
        }
    }
}
#endif
