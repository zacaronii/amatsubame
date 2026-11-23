import Core
import SwiftUI
import UniformTypeIdentifiers

/// Reader settings ▸ Added Fonts: fonts the reader added for books on this device. Choose one to
/// read in, add one from Files, rename or remove them.
struct BookFontsView: View {
    @Bindable var model: BookReaderModel
    let library: BookFontLibrary
    @State private var fonts: [BookFont] = []
    @State private var importing = false
    @State private var problem: String?
    @State private var renaming: BookFont?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(fonts) { font in
                    Button {
                        model.settings.customFont = font.id
                        model.settings.font = .custom
                    } label: {
                        HStack {
                            Text(font.name)
                            Spacer()
                            if model.settings.font == .custom, model.settings.customFont == font.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bookFonts.font")
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") { newName = font.name; renaming = font }
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(font) }
                    }
                    .swipeActions { Button("Remove", role: .destructive) { remove(font) } }
                }
                Button("Add a Font…", systemImage: "plus") { importing = true }
                    .disabled(fonts.count >= BookFont.maxCount)
                    .accessibilityIdentifier("bookFonts.add")
            } footer: {
                Text("Fonts you add are kept on this device, for reading books only (TrueType, OpenType or WOFF, up to 50 MB each).")
            }
        }
        .navigationTitle("Added Fonts")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font]) { result in
            guard case .success(let url) = result else { return }
            add(url)
        }
        .alert("Couldn't Add the Font", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .alert("Rename Font", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let font = renaming { try? library.store.rename(font.id, to: newName) }
                reload()
            }
        }
        .task { reload() }
    }

    private func reload() { fonts = (try? library.store.fonts()) ?? [] }

    private func add(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let font = try library.add(url)
            model.settings.customFont = font.id
            model.settings.font = .custom
        } catch {
            problem = error.localizedDescription
        }
        reload()
    }

    private func remove(_ font: BookFont) {
        try? library.remove(font.id)
        // Reading in it: back to the book's own font.
        if model.settings.customFont == font.id {
            model.settings.customFont = nil
            if model.settings.font == .custom { model.settings.font = .book }
        }
        reload()
    }
}
