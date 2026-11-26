import Core
import SwiftUI

public struct AboutView: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var dictionaries: [DictionaryRecord] = []
    private let credits: [(String, String, String)]
    static let shared: [(String, String, String)] = [
        ("hoshidicts", "GPL-3.0", "Yomitan dictionary import and lookup by Manhhao, in bee-san's fork that Hachidori uses, with Yomitan's Japanese deinflection rules."),
        ("Yomitan", "GPL-3.0", "Dictionary format, deinflection rules and structured-content rendering this app follows."),
        ("GRDB.swift", "MIT", "SQLite toolkit."),
        ("ZIPFoundation", "MIT", "Reading EPUB and subtitle archives."),
        ("glaze, libdeflate, unordered_dense, utf8proc", "MIT", "Used by hoshidicts."),
        ("utfcpp", "BSL-1.0", "Used by hoshidicts."),
        ("xxHash", "BSD-2-Clause", "Used by hoshidicts."),
        ("zstd", "BSD", "Used by hoshidicts."),
        ("AniList", "AniList terms of use", "Character names and pictures for the names dictionary (anilist.co)."),
        ("MangaBaka", "CC BY-NC-SA 4.0", "Which AniList series a manga or light novel is, for the names dictionary (mangabaka.org). Used as published."),
    ]

    /// Credits that link to their source and terms: the data services' terms ask for a credit
    /// with a link (MangaBaka's CC BY-NC-SA: to the licence).
    static let creditLinks: [String: (site: URL, license: URL)] = [
        "AniList": (URL(string: "https://anilist.co")!, URL(string: "https://docs.anilist.co/guide/terms-of-use")!),
        "MangaBaka": (URL(string: "https://mangabaka.org")!, URL(string: "https://creativecommons.org/licenses/by-nc-sa/4.0/")!),
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

    private func feedback(_ kind: Feedback.Kind) -> URL {
        Feedback.url(kind, app: CommonEnvironment.appName, version: "\(CommonEnvironment.appVersion) (\(CommonEnvironment.buildNumber))",
                     device: Feedback.device)
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: "\(CommonEnvironment.appVersion) (\(CommonEnvironment.buildNumber))")
            }
            Section {
                Link(destination: feedback(.bug)) {
                    Label("Report a Bug", systemImage: "ladybug")
                }
                .accessibilityIdentifier("about.reportBug")
                Link(destination: feedback(.idea)) {
                    Label("Suggest an Idea", systemImage: "lightbulb")
                }
                .accessibilityIdentifier("about.suggestIdea")
            } header: {
                Text("Feedback")
            } footer: {
                Text("Opens a GitHub issue with this app, its version and your device filled in. In TestFlight you can also take a screenshot and tap Share Beta Feedback.")
            }
            Section("Open Source") {
                ForEach(credits, id: \.0) { name, license, note in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let links = Self.creditLinks[name] {
                                Link(name, destination: links.site).font(.headline)
                                Spacer()
                                Link(license, destination: links.license).font(.caption)
                            } else {
                                Text(name).font(.headline)
                                Spacer()
                                Text(license).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("about.credit.\(name)")
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
        .formStyle(.grouped)
        .navigationTitle("About")
        .task { dictionaries = (try? environment.dictionaries.dictionaries()) ?? [] }
    }
}

#if os(macOS)
import AppKit

/// App menu ▸ About: the standard About window, with the open-source credits from Settings ▸ About.
public struct AboutCommands: Commands {
    let appCredits: [(String, String, String)]

    /// `appCredits`: the app's own libraries, as in its Settings ▸ About.
    public init(appCredits: [(String, String, String)] = []) {
        self.appCredits = appCredits
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(CommonEnvironment.appName)") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: AboutView.creditsText(appCredits: appCredits)])
                NSApplication.shared.activate()
            }
        }
    }
}

extension AboutView {
    /// The credits as the About window shows them: each library with its licence and use.
    static func creditsText(appCredits: [(String, String, String)]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        func add(_ string: String, font: NSFont, color: NSColor, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let link { attributes[.link] = link }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        add("Open Source\n", font: .boldSystemFont(ofSize: NSFont.systemFontSize), color: .labelColor)
        for (name, license, note) in appCredits + shared {
            let links = creditLinks[name]
            add(name, font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize), color: .labelColor, link: links?.site)
            add(" · ", font: small, color: .secondaryLabelColor)
            add(license, font: small, color: .secondaryLabelColor, link: links?.license)
            add("\n", font: small, color: .secondaryLabelColor)
            add("\(note)\n", font: small, color: .secondaryLabelColor)
        }
        add("\nEach dictionary's licence is in Settings ▸ About.", font: small, color: .secondaryLabelColor)
        return text
    }
}
#endif
