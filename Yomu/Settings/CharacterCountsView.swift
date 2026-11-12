import SwiftUI

/// Settings ▸ Character Counts: counting the Japanese books' characters (Hoshi Reader's rule)
/// so the library's progress is in characters, not Kavita's figures.
struct CharacterCountsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let counter = environment.bookCounter
        Form {
            Section {
                if let survey = counter.survey {
                    LabeledContent("Counted", value: "\(survey.counted) volumes")
                    LabeledContent("Not counted", value: "\(survey.toCount) volumes")
                        .accessibilityIdentifier("counts.toCount")
                } else if counter.isSurveying {
                    HStack {
                        Text("Checking your libraries…")
                        Spacer()
                        ProgressView()
                    }
                }
                if counter.isCounting {
                    VStack(alignment: .leading, spacing: 6) {
                        if counter.job == .newVolumes {
                            Text("Counting new volumes").font(.subheadline)
                        }
                        ProgressView(value: Double(counter.done), total: Double(max(counter.toDo, 1)))
                        Text(counter.toDo == 0 ? "Finding the volumes to count…"
                             : counter.bytes > 0 ? "\(counter.done) of \(counter.toDo) volumes · \(counter.bytes.formatted(.byteCount(style: .file))) downloaded"
                             : "\(counter.done) of \(counter.toDo) volumes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Stop", role: .cancel) { counter.cancel() }
                } else if let survey = counter.survey, survey.toCount > 0 {
                    Button {
                        counter.countLibrary()
                    } label: {
                        Text("Count Characters (about \(survey.estimatedBytes.formatted(.byteCount(style: .file))))")
                    }
                    .accessibilityIdentifier("counts.start")
                }
                if let problem = counter.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if counter.stopped, !counter.isCounting, (counter.survey?.toCount ?? 0) > 0 {
                    Label("Stopped. Counting again picks up where it stopped.", systemImage: "pause.circle").foregroundStyle(.secondary)
                }
            } footer: {
                Text("""
                    Kavita's word count and page percentages are far off for Japanese books, so Yomu counts \
                    characters itself, as Hoshi Reader does: letters only, without punctuation or furigana. \
                    This downloads the text of each light novel, and of books Kavita tags Japanese, without \
                    pictures. The text is only held while its volume is counted and is never saved: Yomu keeps \
                    just the numbers, and nothing is added to your downloads or storage. After the first count, \
                    new volumes are counted on Wi-Fi as they appear.
                    """)
            }
        }
        .navigationTitle("Character Counts")
        .task { await counter.refreshSurvey() }
    }
}
