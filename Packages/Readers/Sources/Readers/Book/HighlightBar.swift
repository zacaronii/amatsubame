import Core
import SwiftUI

/// Above the book's lookup popup: highlight the sentence the word is in (in one of Kavita's
/// five colours), write a note on it, or remove its highlight. Kept on Kavita as annotations.
struct HighlightBar: View {
    let model: BookReaderModel

    var body: some View {
        if let marks = model.marks, marks.canHighlight {
            let tapped = model.tappedHighlight
            HStack(spacing: 10) {
                ForEach(0..<BookMarks.slotColors.count, id: \.self) { slot in
                    Button {
                        model.highlightTapped(slot: slot)
                    } label: {
                        Circle()
                            .fill(Self.color(slot))
                            .frame(width: 22, height: 22)
                            .overlay { Circle().strokeBorder(.primary.opacity(tapped?.slot == slot ? 0.8 : 0.15), lineWidth: tapped?.slot == slot ? 2 : 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tapped == nil ? "Highlight the Sentence, Colour \(slot + 1)" : "Colour \(slot + 1)")
                    .accessibilityAddTraits(tapped?.slot == slot ? .isSelected : [])
                    .accessibilityIdentifier("highlight.colour.\(slot)")
                }
                Spacer(minLength: 4)
                Button(tapped?.note == nil ? "Add Note" : "Edit Note", systemImage: "note.text") { model.noteOnTapped() }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("highlight.note")
                if tapped != nil {
                    Button("Remove Highlight", systemImage: "trash", role: .destructive) { model.removeTappedHighlight() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("highlight.remove")
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(tapped == nil ? "highlight.bar" : "highlight.bar.highlighted")
        }
    }

    /// The slot's colour (Kavita's default, opaque enough to see on the popup).
    static func color(_ slot: Int) -> Color {
        [Color(red: 0, green: 1, blue: 1), Color(red: 0, green: 1, blue: 0), Color(red: 1, green: 1, blue: 0),
         Color(red: 1, green: 0.65, blue: 0), Color(red: 1, green: 0, blue: 1)][min(max(slot, 0), 4)].opacity(0.6)
    }
}

/// Writes a highlight's note (plain text; Kavita keeps it as rich text).
struct NoteEditor: View {
    let mark: ReaderMark
    let save: (String?) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(mark.text ?? "").foregroundStyle(.secondary)
                }
                Section("Note") {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("note.text")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(text)
                        dismiss()
                    }
                    .accessibilityIdentifier("note.save")
                }
            }
        }
        .onAppear { text = mark.note ?? "" }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
