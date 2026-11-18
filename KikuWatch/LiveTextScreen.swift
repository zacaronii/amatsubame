import KikuWatchLink
import SwiftUI

/// Live Text (docs/watch.md): the transcript following the iPhone, earlier lines dimmed above the
/// line playing. The crown scrolls back (leaving "follow"); a tapped line gets Mark and Replay;
/// a tapped word is looked up on the phone, and + mines it there.
struct LiveTextScreen: View {
    @Environment(WatchSession.self) private var session
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ZStack {
            if let playing = session.nowPlaying, playing.transcript != nil, let transcript = session.transcript {
                // Twice a second while playing, so a new line shows on time; once a minute with
                // the wrist down (Always On).
                TimelineView(.periodic(from: .now, by: isLuminanceReduced || !playing.isPlaying ? 60 : 0.5)) { context in
                    LiveLines(transcript: transcript, current: transcript.index(at: playing.position(at: context.date)))
                }
            } else {
                waiting
            }
            if let notice = session.notice {
                Text(notice)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if let lookup = session.lookup {
                LookupCard(state: lookup)
                    .transition(.opacity)
            }
            if let confirmation = session.confirmation {
                ConfirmationCard(confirmation: confirmation)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.confirmation)
        .animation(.easeInOut(duration: 0.2), value: session.lookup)
        .navigationTitle("Live Text")
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote").font(.title2).foregroundStyle(.tint)
            Text(waitingText)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier("watch.liveText.waiting")
    }

    private var waitingText: String {
        guard let playing = session.nowPlaying else { return "Start something in Kiku on your iPhone" }
        if playing.transcript == nil {
            return session.liveTextOn ? "This episode has no transcript yet" : "Turn on Live Text in Kiku ▸ Settings ▸ Playback on your iPhone"
        }
        return "Getting the transcript from your iPhone…"
    }
}

private struct LiveLines: View {
    @Environment(WatchSession.self) private var session
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let transcript: WatchTranscript
    let current: Int?
    @State private var follows = true
    /// A line tapped while scrolled back: it gets Mark and Replay.
    @State private var chosen: Int?

    /// The earlier lines kept on screen (enough to scroll back through a few minutes).
    static let shownBefore = 150

    private var shown: ArraySlice<WatchTranscript.Line> {
        guard let current else { return [] }
        return transcript.lines[max(current - Self.shownBefore, 0)...current]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if current == nil {
                        Text("The first line is coming up").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(shown, id: \.position) { line in
                        LineRow(line: line, focus: focus(of: line.position)) { choose(line.position) }
                    }
                }
                .padding(.bottom, follows ? 0 : 36)
            }
            .opacity(isLuminanceReduced ? 0.6 : 1)
            .onScrollPhaseChange { _, phase in
                // The crown or a swipe: stop following until Back to Now.
                if phase == .interacting { follows = false }
            }
            .overlay(alignment: .bottom) {
                if !follows {
                    Button {
                        follows = true
                        chosen = nil
                        scroll(proxy, animated: true)
                    } label: {
                        Label("Back to now", systemImage: "arrow.down").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .accessibilityIdentifier("watch.liveText.backToNow")
                }
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: current) { if follows { scroll(proxy, animated: !isLuminanceReduced) } }
            // Wrist raised: straight to the line playing.
            .onChange(of: isLuminanceReduced) { _, reduced in if !reduced && follows { scroll(proxy, animated: false) } }
        }
    }

    private func focus(of position: Int) -> LineRow.Focus {
        if position == chosen { return .chosen }
        return chosen == nil && position == current ? .playing : .none
    }

    private func choose(_ position: Int) {
        follows = false
        chosen = position
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let current else { return }
        if animated {
            withAnimation { proxy.scrollTo(current, anchor: .bottom) }
        } else {
            proxy.scrollTo(current, anchor: .bottom)
        }
    }
}

/// One line: small and dimmed, or (the line playing, or the one chosen) large, each character
/// tappable, its time below, and Mark Line (with Replay for a chosen line).
private struct LineRow: View {
    enum Focus { case none, playing, chosen }

    let line: WatchTranscript.Line
    let focus: Focus
    let onChoose: () -> Void

    var body: some View {
        if focus == .none {
            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: onChoose)
        } else {
            FocusedLine(line: line, isChosen: focus == .chosen)
        }
    }
}

private struct FocusedLine: View {
    @Environment(WatchSession.self) private var session
    let line: WatchTranscript.Line
    let isChosen: Bool

    private var highlighted: Range<Int>? {
        guard let lookup = session.lookup, lookup.line == line.position else { return nil }
        return lookup.result?.range ?? lookup.character..<(lookup.character + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WordFlow(text: line.text, highlighted: highlighted) { character in
                session.lookUp(line, character: character)
            }
            Text(line.start.watchClock)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button { session.markLine(line) } label: {
                    Label(isChosen ? "Mark" : "Mark Line", systemImage: "bookmark").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("watch.liveText.markLine")
                if isChosen {
                    Button { session.replay(line) } label: {
                        Label("Replay", systemImage: "play.fill").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("watch.liveText.replay")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A line whose characters can each be tapped (SwiftUI's `Text` doesn't say which was), wrapped
/// to the width. Character indices count `Character`s, as the phone's lookup does.
private struct WordFlow: View {
    let text: String
    let highlighted: Range<Int>?
    let onTap: (Int) -> Void

    var body: some View {
        let characters = Array(text)
        FlowLayout {
            ForEach(characters.indices, id: \.self) { index in
                Text(String(characters[index]))
                    .font(.system(size: 20))
                    .foregroundStyle(highlighted?.contains(index) ?? false ? Color.black : Color.primary)
                    .background(highlighted?.contains(index) ?? false ? Color.accentColor : .clear)
                    .contentShape(.rect)
                    .onTapGesture { onTap(index) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("watch.liveText.current")
    }
}

/// Lays its views out left to right, wrapping at the width (Japanese needs no word breaks).
private struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height }
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.indices.append(index)
            row.width += size.width
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The word looked up on the phone: headword, reading, first meaning, frequency and lookup
/// count, with + to add the card there.
private struct LookupCard: View {
    @Environment(WatchSession.self) private var session
    let state: WatchSession.LookupState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let result = state.result {
                    Text(result.expression).font(.system(size: 26, weight: .semibold))
                    if result.reading != result.expression {
                        Text(result.reading).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let meaning = result.meaning {
                        Text(meaning).font(.footnote).padding(.top, 2)
                    }
                    HStack(spacing: 6) {
                        if let frequency = result.frequency {
                            Label(frequency, systemImage: "chart.bar.fill")
                        }
                        if let count = result.lookupCount {
                            Text(count == 1 ? "First lookup" : "Looked up \(count) times")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Button { session.addCard() } label: {
                        Label(result.isMined ? "Add again" : "Add card", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                    .accessibilityIdentifier("watch.lookup.add")
                    if result.isMined {
                        Text("Already in your deck").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .overlay(alignment: .topTrailing) {
            Button { session.closeLookup() } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .clipShape(.circle)
            .frame(width: 28, height: 28)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("watch.lookup.close")
        }
        .accessibilityIdentifier("watch.lookup")
    }
}
