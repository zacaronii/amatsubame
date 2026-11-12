import Core
import Lookup
import SwiftUI

public struct AudioSourcesView: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var sources: [AudioSourceRecord] = []
    @State private var editing: AudioSourceRecord?

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    Button {
                        var source = source
                        source.template = environment.lookup.audio.editableTemplate(source)
                        editing = source
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name).foregroundStyle(.primary)
                                Text(source.kind == .jpod101 ? "Built in" : AudioSourceKeys.masked(source.template))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if !source.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .reorderMenu(index: index, count: sources.count, move: move)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            } header: {
                Text("Sources")
            } footer: {
                Text("Tried in order; the first source with audio plays. \(ReorderMenu.hint) Templates use {term} and {reading}.")
            }
            Section {
                Button("Add Source", systemImage: "plus") {
                    editing = AudioSourceRecord(kind: .json, name: "Local audio", template: "http://", sortOrder: sources.count)
                }
                Button("Test with 食べる", systemImage: "speaker.wave.2") {
                    environment.lookup.audio.play(term: "食べる", reading: "たべる")
                }
                if case .playing(let source) = environment.lookup.audio.status {
                    Text("Playing from \(source)").font(.caption).foregroundStyle(.secondary)
                } else if environment.lookup.audio.status == .unavailable {
                    Text("No source had audio.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Audio Sources")
        .toolbar {
            #if os(iOS)
            EditButton()
            #endif
        }
        .sheet(item: $editing) { source in
            AudioSourceEditor(source: source) { saved in
                save(saved)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .task { reload() }
    }

    private func reload() {
        sources = (try? environment.lookup.audio.sources()) ?? []
    }

    // Through the lookup's audio service: its database is the shared setup's when this app shares it.
    private func save(_ source: AudioSourceRecord) {
        try? environment.lookup.audio.save(source)
        reload()
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
        try? environment.lookup.audio.reorder(sources)
        reload()
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { sources[$0].id }
        try? environment.lookup.audio.delete(ids: ids)
        reload()
    }
}

extension AudioSourceRecord.Kind {
    var label: String {
        switch self {
        case .jpod101: "JapanesePod101"
        case .url: "Audio file URL"
        case .json: "Audio list (JSON)"
        }
    }
}

private struct AudioSourceEditor: View {
    @State var source: AudioSourceRecord
    @State private var showsTemplate = false
    let onSave: (AudioSourceRecord) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $source.name)
                Picker("Type", selection: $source.kind) {
                    ForEach(AudioSourceRecord.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if source.kind != .jpod101, AudioSourceKeys.hasSecret(source.template), !showsTemplate {
                    Section {
                        Text(AudioSourceKeys.masked(source.template)).font(.callout).foregroundStyle(.secondary)
                        Button("Show URL to Edit") { showsTemplate = true }
                    } footer: {
                        Text("Its key is hidden, and kept in the Keychain.")
                    }
                } else if source.kind != .jpod101 {
                    Section {
                        TextField("URL template", text: $source.template, axis: .vertical)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                    } footer: {
                        Text(source.kind == .json
                             ? "Returns Yomitan's audio list JSON, e.g. a local audio server: http://host:5050/?term={term}&reading={reading}"
                             : "Returns an audio file. {term} and {reading} are replaced.")
                    }
                }
                Toggle("Enabled", isOn: $source.enabled)
            }
            .formStyle(.grouped)
            .navigationTitle(source.id == nil ? "Add Source" : "Edit Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(source) }
                        .disabled(source.name.isEmpty || (source.kind != .jpod101 && !source.template.contains("{")))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }
}
