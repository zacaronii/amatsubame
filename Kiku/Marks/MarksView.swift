import AppCommon
import AudiobookshelfKit
import Core
import SwiftUI

/// The Marks tab (K7/K8): marks made while listening, grouped by episode, to mine later; and
/// search across your marks and the transcripts saved on this device for episodes you've played.
struct MarksView: View {
    @Environment(KikuEnvironment.self) private var environment
    @State private var model: MarksModel?
    @State private var query = ""
    @State private var results: [AudioSearchGroup] = []
    @State private var opening: String?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Marks")
            .toolbar {
                if let model, model.toMine > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        Text("\(model.toMine) to mine").foregroundStyle(.tint).accessibilityIdentifier("marks.toMine")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search marks and what you've played")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                results = (try? environment.transcripts.search(query)) ?? []
            }
        }
        .task {
            let model = model ?? MarksModel(environment: environment)
            self.model = model
            await model.observe()
        }
        .onAppear { model?.reloadLines() }
        .onDisappear { model?.discard() }
        .sheet(item: Binding(get: { model?.lookup.popup }, set: { if $0 == nil { model?.popupClosed() } })) { popup in
            if let model { KikuLookupSheet(model: model, popup: popup) }
        }
    }

    @ViewBuilder
    private func content(_ model: MarksModel) -> some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults(model)
        } else if model.marks.isEmpty {
            ContentUnavailableView {
                Label("No Marks Yet", systemImage: "bookmark")
            } description: {
                Text("Marks you make while listening show up here.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let problem = model.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(model.groups) { group in
                        EpisodeHeader(mark: group.first, count: group.marks.count).padding(.top, 8)
                        ForEach(group.marks) { mark in
                            MarkCard(model: model, mark: mark)
                        }
                    }
                }
                .padding()
            }
            .refreshable { await model.refresh() }
        }
    }

    // MARK: Search (K8)

    private func searchResults(_ model: MarksModel) -> some View {
        let marks = model.matching(query)
        return List {
            if !marks.isEmpty {
                Section("In your marks · \(marks.count)") {
                    ForEach(marks) { mark in
                        MarkCard(model: model, mark: mark)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                }
            }
            if !results.isEmpty {
                Section {
                    ForEach(results) { group in
                        ForEach(group.sentences, id: \.position) { sentence in
                            row(group.transcript, sentence)
                        }
                    }
                } header: {
                    Text("In episodes you've played · \(results.reduce(0) { $0 + $1.sentences.count })")
                } footer: {
                    Text("Searches the transcripts saved on this device, so it works offline.")
                }
            }
            if marks.isEmpty && results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func row(_ info: AudioTranscriptInfo, _ sentence: AudioSentence) -> some View {
        Button {
            Task { await open(info, at: sentence) }
        } label: {
            HStack(spacing: 12) {
                ShowCover(itemId: info.itemId).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.highlighted(sentence.text, query)).lineLimit(2)
                    Text("\(sentence.start.clockText) · \(info.showTitle) · \(info.episodeTitle)")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if opening == "\(info.key)#\(sentence.position)" { ProgressView() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("marks.result")
    }

    /// Opens the player at the line (finding the episode in the library, or its download offline).
    private func open(_ info: AudioTranscriptInfo, at sentence: AudioSentence) async {
        opening = "\(info.key)#\(sentence.position)"
        defer { opening = nil }
        if let entry = await environment.entry(itemId: info.itemId, episodeId: info.episodeId, showTitle: info.showTitle) {
            environment.play(entry, at: sentence.start)
        }
    }

    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        // Like the search itself: any case, and full- or half-width letters.
        while let range = attributed[searchStart...].range(of: needle, options: [.caseInsensitive, .widthInsensitive]) {
            attributed[range].foregroundColor = Color("AccentColor")
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return attributed
    }
}

/// An episode's artwork, title and "show · 2 marks" above its marks.
private struct EpisodeHeader: View {
    let mark: AudioMark
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ShowCover(itemId: mark.itemId, cornerRadius: 10).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(mark.episodeTitle).font(.headline).lineLimit(2)
                Text("\(mark.showTitle) · \(count == 1 ? "1 mark" : "\(count) marks")")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// One mark (K7): its clip, time and how it was made, the lines around it with the likely one
/// emphasized (tap a word to look it up and mine), and Clear. A mined mark fades.
private struct MarkCard: View {
    @Environment(CommonEnvironment.self) private var common
    let model: MarksModel
    let mark: AudioMark

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { Task { await model.playClip(of: mark) } } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Color(red: 0x3A / 255, green: 0x1A / 255, blue: 0x05 / 255))
                        .frame(width: 44, height: 44)
                        .background(.tint, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Stop the clip" : "Play the 15 seconds before the mark")
                .accessibilityIdentifier("mark.play")
                VStack(alignment: .leading, spacing: 2) {
                    Text(mark.time.clockText).font(.title3.weight(.semibold).monospacedDigit())
                    Text(Self.made(mark)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if window == nil {
                    Label("Transcribing", systemImage: "hourglass")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: .capsule)
                }
            }
            if let window {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(window.lines, id: \.position) { sentence in
                        let isMarked = sentence.position == window.marked
                        VStack(alignment: .leading) {
                            TappableLine(text: sentence.text,
                                         highlighted: model.lookup.highlightedRange(for: "\(mark.id ?? 0)-\(sentence.position)"),
                                         marks: common.wordMarks.marks(for: TappableLine.sentence(sentence.text)),
                                         fontSize: isMarked ? 21 : 17, alignment: .leading) { index in
                                Task { await model.tap(sentence, of: mark, characterIndex: index) }
                            }
                            .fontWeight(isMarked ? .semibold : .regular)
                            .opacity(isMarked ? 1 : 0.55)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(isMarked ? "mark.markedLine" : "mark.line")
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 3) }
            } else {
                Text("The 15-second clip still plays; the lines fill in when Kaku finishes.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let word = mark.minedWord {
                Label("Mined \(word)", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            } else {
                HStack {
                    if window != nil {
                        Text("Tap a word to look it up and mine it").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") { model.clear(mark) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .accessibilityIdentifier("mark.clear")
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .opacity(mark.isMined ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mark")
    }

    private var window: (lines: ArraySlice<AudioSentence>, marked: Int)? { model.window(for: mark) }
    private var isPlaying: Bool { model.clip.isPlaying && model.playingMark == mark.id }

    /// "By shortcut · today 8:12".
    static func made(_ mark: AudioMark) -> String {
        let how = switch mark.source {
        case .shortcut: "By shortcut"
        case .nowPlaying: "From Now Playing"
        case .player: "In the player"
        case .headphones: "With headphones"
        }
        let time = mark.createdAt.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        let when = calendar.isDateInToday(mark.createdAt) ? "today \(time)"
            : calendar.isDateInYesterday(mark.createdAt) ? "yesterday \(time)"
            : mark.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(how) · \(when)"
    }
}
