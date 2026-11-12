import Core
import SwiftUI

public struct AboutView: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var dictionaries: [DictionaryRecord] = []
    private let credits: [(String, String, String)]
    private static let shared: [(String, String, String)] = [
        ("hoshidicts", "GPL-3.0", "Yomitan dictionary import and lookup by Manhhao, with Yomitan's Japanese deinflection rules."),
        ("Yomitan", "GPL-3.0", "Dictionary format, deinflection rules and structured-content rendering this app follows."),
        ("GRDB.swift", "MIT", "SQLite toolkit."),
        ("ZIPFoundation", "MIT", "Reading EPUB and subtitle archives."),
        ("glaze, libdeflate, unordered_dense, utf8proc", "MIT", "Used by hoshidicts."),
        ("utfcpp", "BSL-1.0", "Used by hoshidicts."),
        ("xxHash", "BSD-2-Clause", "Used by hoshidicts."),
        ("zstd", "BSD", "Used by hoshidicts."),
    ]

    /// `appCredits` are the app's own libraries, listed before the shared ones.
    public init(appCredits: [(String, String, String)] = []) {
        credits = appCredits + Self.shared
    }

    private func attribution(_ record: DictionaryRecord) -> String {
        let text = record.attribution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        let sources = (try? environment.dictionaries.sources()) ?? [:]
        return RecommendedDictionaries.entry(for: record, source: sources[record.id])?.license ?? "No attribution in its index."
    }

    public var body: some View {
        List {
            Section {
                LabeledContent("Version", value: "\(CommonEnvironment.appVersion) (\(CommonEnvironment.buildNumber))")
            }
            Section("Open Source") {
                ForEach(credits, id: \.0) { name, license, note in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(name).font(.headline)
                            Spacer()
                            Text(license).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(dictionaries) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).font(.headline)
                        Text(attribution(record)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Dictionaries")
            } footer: {
                Text("Each dictionary keeps its own licence and attribution, from its own files.")
            }
            Section("Recommended Dictionaries") {
                ForEach(RecommendedDictionaries.all) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline)
                        Text(entry.license).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("About")
        .task { dictionaries = (try? environment.dictionaries.dictionaries()) ?? [] }
    }
}
