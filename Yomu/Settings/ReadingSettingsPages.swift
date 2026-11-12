import AppCommon
import Core
import OCR
import SwiftUI

/// Settings ▸ Reading ▸ Downloads: when volumes download, and reading their text ahead.
struct ReadingDownloadsView: View {
    var body: some View {
        Form {
            DownloadSettingsSection { settings in
                NavigationLink {
                    AutoDownloadSettingsView()
                } label: {
                    Label("Automatic Downloads", systemImage: "arrow.down.circle.dotted")
                }
                .accessibilityIdentifier("downloads.automatic")
                Toggle("Read Text on Downloaded Pages", isOn: settings.readsDownloadedPages)
                    .accessibilityIdentifier("downloads.readText")
                Text("Downloaded manga pages are read by OCR ahead of time (when the models are installed), so lookups are instant offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Downloads")
    }
}

/// Settings ▸ Reading ▸ Read-Along: Audiobookshelf (the audiobooks) and Kaku (their timed
/// text), together. Optional.
struct ReadAlongSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Form {
            Section {
                // Links by destination: this page also opens from setup, whose stack holds its steps.
                NavigationLink {
                    AudiobookshelfSettingsView(environment: environment.common, tokens: environment.audiobookshelfTokens, appName: "Yomu")
                } label: {
                    ServerRow(kind: .audiobookshelf, account: environment.serverAccounts[.audiobookshelf])
                }
                .accessibilityIdentifier("readAlong.audiobookshelf")
                NavigationLink {
                    KakuSettingsView(environment: environment.common)
                } label: {
                    ServerRow(kind: .kaku, account: environment.serverAccounts[.kaku])
                }
                .accessibilityIdentifier("readAlong.kaku")
            } footer: {
                Text("Read-Along plays a matching audiobook with the text, highlighting each line as it's read. It needs both: Audiobookshelf has the audiobook and Kaku its transcript. It's optional.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Read-Along")
    }
}

/// Settings ▸ Storage: what Yomu keeps on this device, and the counts it makes of books.
struct StorageView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var cacheBytes: Int64 = 0
    @State private var dictionaryBytes: Int64 = 0
    @State private var confirmsClearCache = false

    private var downloadBytes: Int64 {
        environment.downloader.records.values.reduce(0) { $0 + ($1.state == .done ? ($1.bytesTotal ?? 0) : $1.bytesDone) }
    }

    private var modelBytes: Int64 {
        environment.ocrModels.state == .installed ? Int64(OCRModelStore.totalBytes) : 0
    }

    var body: some View {
        Form {
            Section {
                StorageSummary(parts: [
                    .init("Downloads", bytes: downloadBytes, color: .blue),
                    .init("Dictionaries", bytes: dictionaryBytes, color: .purple),
                    .init("Text recognition", bytes: modelBytes, color: .cyan),
                    .init("Cache", bytes: cacheBytes, color: .gray),
                ])
            }
            Section {
                NavigationLink {
                    DownloadedVolumesView()
                } label: {
                    SettingsRowLabel("Downloads", value: downloadBytes.storageText, systemImage: "arrow.down.circle.fill", color: .blue)
                }
                .accessibilityIdentifier("storage.downloads")
                NavigationLink {
                    DictionariesView()
                } label: {
                    SettingsRowLabel("Dictionaries", value: dictionaryBytes.storageText, systemImage: "character.book.closed.ja", color: .purple)
                }
                NavigationLink {
                    OCRSettingsView()
                } label: {
                    SettingsRowLabel("Text Recognition Models", value: modelBytes > 0 ? modelBytes.storageText : "None",
                                     systemImage: "text.viewfinder", color: .cyan)
                }
                HStack {
                    SettingsRowLabel("Cache", value: cacheBytes.storageText, systemImage: "externaldrive.fill", color: .gray)
                    Button("Clear", role: .destructive) { confirmsClearCache = true }
                        .buttonStyle(.borderless)
                        .disabled(cacheBytes == 0)
                        .accessibilityIdentifier("downloads.clearCache")
                }
            } footer: {
                Text("Clearing the cache only removes books, pages and text recognition results that load again when needed. The oldest are removed automatically past 1 GB each.")
            }
            Section {
                NavigationLink {
                    CharacterCountsView()
                } label: {
                    SettingsRowLabel("Character Counts", subtitle: countsSummary, systemImage: "character.textbox", color: .orange)
                }
                .accessibilityIdentifier("storage.characterCounts")
            } header: {
                Text("Library Data")
            } footer: {
                Text("Counts how many characters each book has, for the reading-time estimate and Stats. Reads each book once.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .task { await measure() }
        .confirmationDialog("Clear the cache?", isPresented: $confirmsClearCache, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                try? environment.ocr.cache.clear()
                try? environment.pageCache.clear()
                Task {
                    await environment.books.clear()
                    await measure()
                }
            }
        } message: {
            Text("Downloads stay. Opened books and pages download again the next time you open them, and manga pages are read again.")
        }
    }

    private var countsSummary: String {
        guard let survey = environment.bookCounter.survey else { return "Light novels and Japanese books" }
        let total = survey.counted + survey.toCount
        return "Counted for \(survey.counted) of \(total) volumes"
    }

    private func measure() async {
        let books = await environment.books.unpinnedBytes()
        let pages = (try? environment.pageCache.unpinnedBytes()) ?? 0
        cacheBytes = Int64(books + pages)
        dictionaryBytes = environment.common.dictionaries.totalBytes()
    }
}

/// Settings ▸ Advanced ▸ Troubleshooting: the popup's timing in the reader's corner.
struct LookupTimingsToggle: View {
    @AppStorage("showLookupTimings") private var showsTimings = false

    var body: some View {
        Toggle("Show Lookup Timings", isOn: $showsTimings)
            .accessibilityIdentifier("advanced.lookupTimings")
    }
}
