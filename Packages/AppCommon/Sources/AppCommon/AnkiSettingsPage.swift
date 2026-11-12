import Anki
import Core
import SwiftUI

/// Settings ▸ Lookup and Mining ▸ Anki: the AnkiConnect connection and how cards are made,
/// on one page. `cardExtras`: the app's own rows in Cards
/// (Miru's Card Picture).
public struct AnkiSettingsPage<CardExtras: View>: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var connection: AnkiSettingsModel
    @State private var cards: CardSettingsModel
    private let cardExtras: CardExtras
    /// Shows the picture size (pages): Miru's picture setting replaces it.
    private let showsPictureSize: Bool

    public init(environment: CommonEnvironment, showsPictureSize: Bool = true, @ViewBuilder cardExtras: () -> CardExtras = { EmptyView() }) {
        _connection = State(initialValue: AnkiSettingsModel(environment: environment))
        _cards = State(initialValue: CardSettingsModel(environment: environment))
        self.cardExtras = cardExtras()
        self.showsPictureSize = showsPictureSize
    }

    public var body: some View {
        @Bindable var cards = cards
        Form {
            Section {
                TextField("Server URL", text: $connection.urlText, prompt: Text(verbatim: "http://anki.example.ts.net:8765"))
                    .urlEntry()
                    .accessibilityIdentifier("anki.url")
                SecureField("API Key (optional)", text: $connection.apiKey)
                    .credentialEntry()
                    .accessibilityIdentifier("anki.key")
                Button("Test Connection") {
                    Task {
                        await connection.testAndSave()
                        await cards.load()
                    }
                }
                .disabled(!connection.canTest)
                .accessibilityIdentifier("anki.test")
                ConnectionStatusView(status: connection.status)
            } header: {
                Text("Connection")
            } footer: {
                Text("AnkiConnect runs next to Anki on a computer or server you can reach. Your cards are added there. The API key matches `apiKey` in AnkiConnect's config; leave it blank if none is set.")
            }

            if connection.isConfigured {
                if let error = cards.loadError {
                    Section { Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
                }
                Section {
                    Picker("Deck", selection: $cards.settings.deck) {
                        ForEach(cards.options(cards.decks, current: cards.settings.deck), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Note Type", selection: $cards.settings.noteType) {
                        ForEach(cards.options(cards.noteTypes, current: cards.settings.noteType), id: \.self) { Text($0).tag($0) }
                    }
                    NavigationLink {
                        CardFieldsView(model: cards)
                    } label: {
                        LabeledContent("Fields", value: cards.fieldsSummary)
                    }
                    .accessibilityIdentifier("anki.fields")
                    TextField("Tags", text: $cards.tagsText, prompt: Text("amatsubame"))
                        .autocorrectionDisabled()
                    if showsPictureSize {
                        Stepper("Picture size: \(cards.settings.pictureMaxPixels) px", value: $cards.settings.pictureMaxPixels, in: 400...3000, step: 200)
                    }
                    cardExtras
                } header: {
                    Text("Cards")
                } footer: {
                    Text("Tags are separated by spaces. The picture is the page or video frame the word came from.")
                }

                if cards.decks.contains(where: { $0 != cards.settings.deck }) {
                    Section {
                        NavigationLink {
                            MarkDecksView(model: cards)
                        } label: {
                            LabeledContent("Also Mark Words From", value: cards.settings.markDecks.isEmpty ? "None" : cards.settings.markDecks.joined(separator: ", "))
                        }
                    } header: {
                        Text("Word Marks")
                    } footer: {
                        Text("Words already studied in these decks show as known.")
                    }
                }

                Section {
                    Toggle("Sync to AnkiWeb After Adding", isOn: $cards.settings.syncAfterAdding)
                    Button {
                        Task { await cards.syncNow() }
                    } label: {
                        HStack {
                            Text("Sync Anki Now")
                            if cards.syncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(cards.syncing || environment.ankiClient() == nil)
                    switch cards.lastSync {
                    case .synced(let date):
                        Label("Synced \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(_, let message):
                        Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                } header: {
                    Text("AnkiWeb")
                } footer: {
                    Text("Sends new cards to AnkiMobile about 10 seconds after they arrive, once for a batch.")
                }

                Section {
                    Button("Remove Server", role: .destructive) { connection.remove() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Anki")
        .task { await cards.load() }
    }
}

/// What goes in each field of the note type.
struct CardFieldsView: View {
    let model: CardSettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.fieldNames, id: \.self) { field in
                    Picker(field, selection: model.binding(for: field)) {
                        Text("Nothing").tag(CardSettingsModel.FieldChoice.nothing)
                        ForEach(AnkiContentSlot.allCases, id: \.self) { Text($0.displayName).tag(CardSettingsModel.FieldChoice.slot($0)) }
                        if case .constant(let text) = model.settings.fields[field] {
                            Text("“\(text)”").tag(CardSettingsModel.FieldChoice.constant(text))
                        } else {
                            Text("“x”").tag(CardSettingsModel.FieldChoice.constant("x"))
                        }
                    }
                }
                if !model.fieldNames.isEmpty {
                    Button("Reset to Default") { model.resetFields() }
                }
            } footer: {
                Text(model.fieldNames.isEmpty
                     ? "Connect to AnkiConnect to see the note type's fields."
                     : "“x” turns on Lapis card types: by default each card is a word + sentence card.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Fields")
    }
}

/// Other decks whose studied cards count for word marks.
struct MarkDecksView: View {
    @Bindable var model: CardSettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.decks.filter { $0 != model.settings.deck }, id: \.self) { deck in
                    Toggle(deck, isOn: Binding {
                        model.settings.markDecks.contains(deck)
                    } set: { on in
                        model.settings.markDecks.removeAll { $0 == deck }
                        if on { model.settings.markDecks.append(deck) }
                    })
                }
            } footer: {
                Text("Word marks also count studied cards in these decks (the word is each note\u{2019}s first field). Cards you haven\u{2019}t started stay marked as not in Anki.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Also Mark Words From")
    }
}
