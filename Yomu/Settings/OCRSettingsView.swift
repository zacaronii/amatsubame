import OCR
import SwiftUI

/// Settings ▸ Reading ▸ Manga Text Recognition: the models. Its cache is cleared with the
/// others in Storage, and Show Lookup Timings is in Advanced.
struct OCRSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let store = environment.ocrModels
        List {
            Section {
                switch store.state {
                case .notInstalled:
                    Button("Download Models (\(OCRModelStore.totalBytes.formatted(.byteCount(style: .file))))", systemImage: "arrow.down.circle") {
                        store.install()
                    }
                    .accessibilityIdentifier("ocr.download")
                case .downloading(let fraction):
                    ProgressView(value: fraction) { Text("Downloading…") }
                    Button("Cancel", role: .cancel) { store.cancel() }
                case .compiling:
                    HStack { ProgressView(); Text("Preparing models…") }
                case .installed:
                    Label("Models installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Delete Models", role: .destructive) {
                        store.delete()
                        Task { await environment.ocr.unloadModels() }
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again") { store.install() }
                }
            } header: {
                Text("Text Recognition")
            } footer: {
                Text("Detects speech bubbles and reads them on this device (manga-ocr and a comic text detector, Apache-2.0). Downloaded once from Hugging Face.")
            }
        }
        .navigationTitle("Manga Text Recognition")
        .onChange(of: store.state) { _, state in
            // Downloaded volumes waiting for their text can be read now.
            if state == .installed { environment.downloader.resumeTextReading() }
        }
    }
}
