import Anki
import Core
import Observation
import SwiftUI

/// Where mined cards go and what each field gets: what the Anki page, its Fields and Word
/// Marks pages, and setup's deck-and-fields step all edit. Saved as it changes.
@Observable
public final class CardSettingsModel {
    public var settings = AnkiSettings.default {
        didSet { if loaded && settings != oldValue { changed(from: oldValue) } }
    }
    public var tagsText = "" {
        didSet { settings.tags = tagsText.split(whereSeparator: \.isWhitespace).map(String.init) }
    }
    public private(set) var decks: [String] = []
    public private(set) var noteTypes: [String] = []
    public private(set) var fieldNames: [String] = []
    public private(set) var loadError: String?
    public private(set) var loaded = false
    public private(set) var syncing = false
    public private(set) var lastSync: AnkiSyncScheduler.Outcome?

    @ObservationIgnored private let environment: CommonEnvironment

    public init(environment: CommonEnvironment) {
        self.environment = environment
    }

    /// The saved settings, then the server's decks, note types and fields.
    public func load() async {
        lastSync = await environment.ankiSync.lastOutcome
        settings = (try? environment.ankiSettings.settings()) ?? .default
        tagsText = settings.tags.joined(separator: " ")
        guard let client = environment.ankiClient() else {
            loadError = "AnkiConnect isn't set up."
            loaded = true
            return
        }
        do {
            async let decks = client.deckNames()
            async let models = client.modelNames()
            self.decks = try await decks.sorted()
            noteTypes = try await models.sorted()
            loadError = nil
        } catch {
            loadError = "Couldn't reach AnkiConnect, so only the saved settings are shown."
        }
        await loadFields(resetMapping: false)
        loaded = true
    }

    /// The server's names, plus the saved value if the server didn't list it (offline).
    public func options(_ names: [String], current: String) -> [String] {
        names.contains(current) ? names : [current] + names
    }

    /// "9 of 11 filled".
    public var fieldsSummary: String {
        guard !fieldNames.isEmpty else { return settings.fields.isEmpty ? "None" : "\(settings.fields.count) filled" }
        return "\(fieldNames.filter { settings.fields[$0] != nil }.count) of \(fieldNames.count) filled"
    }

    public func resetFields() {
        settings.fields = AnkiSettings.presetFields(for: fieldNames)
    }

    public func syncNow() async {
        syncing = true
        lastSync = await environment.ankiSync.syncNow()
        syncing = false
    }

    private func changed(from old: AnkiSettings) {
        try? environment.ankiSettings.save(settings)
        if old.noteType != settings.noteType {
            Task {
                await loadFields(resetMapping: true)
                await environment.refreshMinedWords()
            }
        } else if old.deck != settings.deck || old.markDecks != settings.markDecks {
            Task { await environment.refreshMinedWords() }
        }
    }

    private func loadFields(resetMapping: Bool) async {
        guard let client = environment.ankiClient(), let names = try? await client.modelFieldNames(settings.noteType) else { return }
        fieldNames = names
        if resetMapping { settings.fields = AnkiSettings.presetFields(for: names) }
    }

    // MARK: Fields

    public enum FieldChoice: Hashable {
        case nothing
        case slot(AnkiContentSlot)
        case constant(String)
    }

    public func binding(for field: String) -> Binding<FieldChoice> {
        Binding {
            switch self.settings.fields[field] {
            case .slot(let slot): .slot(slot)
            case .constant(let text): .constant(text)
            case nil: .nothing
            }
        } set: { choice in
            switch choice {
            case .nothing: self.settings.fields[field] = nil
            case .slot(let slot): self.settings.fields[field] = .slot(slot)
            case .constant(let text): self.settings.fields[field] = .constant(text)
            }
        }
    }
}
