import Core
import SwiftUI

/// Writing or changing a mark's note: Return starts a new line, ⌘Return or Done saves, and
/// clearing the text removes the note. Capped at `AudioMark.noteLimit` characters.
struct MarkNoteSheet: View {
    let mark: AudioMark
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(mark: AudioMark, onSave: @escaping (String) -> Void) {
        self.mark = mark
        self.onSave = onSave
        _text = State(initialValue: mark.note ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(mark.episodeTitle) · \(mark.time.clockText)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("markNote.text")
                    .onChange(of: text) { _, new in
                        if new.count > AudioMark.noteLimit { text = String(new.prefix(AudioMark.noteLimit)) }
                    }
                if text.count > AudioMark.noteLimit - 200 {
                    Text("\(text.count) / \(AudioMark.noteLimit)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle(mark.note == nil ? "Add Note" : "Edit Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(text)
                        dismiss()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("markNote.done")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
