import Core
import Lookup
import SwiftUI

/// Settings ▸ Anki ▸ Known and Ignored Words: the words marked by hand (the popup's Known and
/// Ignore), shared by the apps and, while it's on, with Hachidori. Like Hachidori's Known words
/// box, a list can be pasted in, one word per line.
struct KnownWordsView: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var adding = ""
    @State private var added: Int?

    var body: some View {
        let lookup = environment.lookup
        Form {
            Section {
                TextField("One word per line, in dictionary form", text: $adding, axis: .vertical)
                    .lineLimit(3...8)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("knownWords.text")
                Button("Mark as Known") {
                    added = lookup.addKnownWords(adding.components(separatedBy: .newlines))
                    adding = ""
                }
                .disabled(adding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("knownWords.add")
            } header: {
                Text("Add Known Words")
            } footer: {
                if let added {
                    Text(added == 1 ? "1 word marked as known." : "\(added) words marked as known.")
                }
            }
            section(.known, title: "Known", lookup: lookup)
            section(.ignored, title: "Ignored", lookup: lookup)
        }
        .formStyle(.grouped)
        .navigationTitle("Known and Ignored Words")
        .onAppear { lookup.reloadWordStatuses() }
    }

    @ViewBuilder
    private func section(_ status: WordStatus, title: String, lookup: LookupService) -> some View {
        let words = lookup.wordStatuses.filter { $0.value == status }.keys.sorted()
        Section {
            if words.isEmpty {
                Text(status == .known ? "No words yet. Tap the check in a lookup to mark a word you know."
                     : "No words yet. Tap the crossed-out eye in a lookup for a word you don't want marked.")
                    .foregroundStyle(.secondary)
            }
            ForEach(words, id: \.self) { word in
                Text(word).lineLimit(1)
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) { lookup.setWordStatus(nil, for: [word]) }
                    }
            }
            .onDelete { offsets in lookup.setWordStatus(nil, for: offsets.map { words[$0] }) }
        } header: {
            Text("\(title) (\(words.count))")
        } footer: {
            if status == .ignored {
                Text("Known and ignored words are never marked in text, whatever their Anki cards say. With Hachidori on, this list is Hachidori's too.")
            }
        }
    }
}
