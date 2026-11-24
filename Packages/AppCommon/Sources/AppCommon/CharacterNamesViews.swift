import Core
import GRDB
import Names
import SwiftUI

/// What Settings shows of the names dictionary: each open series, its AniList match and cast.
@Observable
final class CharacterNamesModel {
    struct Row: Identifiable, Equatable {
        var app: String
        var series: NamedSeries
        /// The cast's series on AniList (nil: not matched yet, or the user said none).
        var castTitle: String?
        var characters: Int
        var needsPick: Bool
        var id: String { app }
    }

    var enabled = true
    var rows: [Row] = []

    /// Follows the open series, their matches and casts.
    func observe(_ environment: CommonEnvironment) async {
        let database = environment.dictionaries.database
        let values = database.values { db -> (Bool, [Row]) in
            let enabled = try CharacterNameSettings.fetchOne(db, key: 1)?.enabled ?? true
            let rows = try CharacterNameOpenSeries.order(Column("app")).fetchAll(db).map { open -> Row in
                let match = try CharacterNameMatch.fetchOne(db, key: open.seriesKey)
                let cast = try match?.mediaKey.flatMap { try CharacterCastRecord.fetchOne(db, key: $0) }
                let count = cast.flatMap { try? JSONDecoder().decode([AniListCharacter].self, from: $0.characters) }?.count ?? 0
                let series = NamedSeries(key: open.seriesKey, title: match?.title ?? "", type: NamedSeries.type(ofKey: open.seriesKey))
                return Row(app: open.app, series: series, castTitle: cast?.title, characters: count,
                           needsPick: match != nil && match?.mediaKey == nil && match?.source != .picked)
            }
            return (enabled, rows)
        }
        do {
            for try await (enabled, rows) in values {
                self.enabled = enabled
                self.rows = rows
            }
        } catch {}
    }
}

/// Settings ▸ Dictionaries ▸ Character Names: the switch and the series it holds now.
struct CharacterNamesSection: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var model = CharacterNamesModel()
    @State private var picking: NamedSeries?

    var body: some View {
        Section {
            Toggle("Names from What's Open", isOn: Binding(get: { model.enabled }, set: { on in
                model.enabled = on
                Task { try? await environment.characterNames.setEnabled(on) }
            }))
            .accessibilityIdentifier("dictionaries.characterNames")
            if model.enabled {
                ForEach(model.rows) { row in
                    Button {
                        picking = row.series
                    } label: {
                        LabeledContent {
                            Text(row.needsPick ? "Pick the Series" : row.castTitle == nil ? "None" : "\(row.characters) characters")
                                .foregroundStyle(row.needsPick ? Color.accentColor : .secondary)
                        } label: {
                            Text(row.series.title.isEmpty ? row.app.capitalized : row.series.title)
                            if let cast = row.castTitle, cast != row.series.title { Text(cast) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        } header: {
            Text("Character Names")
        } footer: {
            Text("The characters of the series open in Yomu and Miru, from AniList, with their pictures: looked up just above JMnedict. Tap a series to change which AniList series it is.")
        }
        .task { await model.observe(environment) }
        .sheet(item: $picking) { series in
            CharacterNamePicker(series: series)
        }
    }
}

extension NamedSeries: Identifiable {
    public var id: String { key }
}

/// Which AniList series a series of ours is, for its character names: a title search to pick
/// from, or none.
public struct CharacterNamePicker: View {
    @Environment(CommonEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let series: NamedSeries
    @State private var query: String
    @State private var results: [AniListMedia] = []
    @State private var searching = false
    @State private var error: String?

    public init(series: NamedSeries) {
        self.series = series
        _query = State(initialValue: series.title)
    }

    public var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                }
                ForEach(results) { media in
                    Button {
                        choose(media)
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: media.cover) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.secondary.opacity(0.15)
                            }
                            .frame(width: 40, height: 56)
                            .clipShape(.rect(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(media.displayTitle)
                                if let romaji = media.title.romaji, romaji != media.displayTitle {
                                    Text(romaji).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(Self.details(media)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Section {
                    Button("None of These", role: .destructive) { choose(nil) }
                } footer: {
                    Text("Character names and pictures come from AniList.")
                }
            }
            .overlay {
                if searching && results.isEmpty { ProgressView() }
            }
            .searchable(text: $query, prompt: "Title")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("Pick the Series")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await search() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    static func details(_ media: AniListMedia) -> String {
        let format = media.format.map { $0 == "TV" ? "TV" : $0.replacingOccurrences(of: "_", with: " ").capitalized }
        let year = (media.seasonYear ?? media.startYear).map(String.init)
        return [format, year, media.episodes.map { "\($0) episodes" }].compactMap(\.self).joined(separator: " · ")
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await environment.characterNames.candidates(text, type: series.type)
            error = results.isEmpty ? "AniList has nothing called “\(text)”." : nil
        } catch {
            self.error = "AniList can't be reached right now."
        }
    }

    private func choose(_ media: AniListMedia?) {
        Task {
            try? await environment.characterNames.pick(media, for: series)
            dismiss()
        }
    }
}
