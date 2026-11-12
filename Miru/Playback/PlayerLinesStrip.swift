import AppCommon
import PlayerKit
import SwiftUI

/// The episode's Japanese lines under the picture (D4): the line playing highlighted and kept
/// in view, word marks, a tap on a word looks it up and a tap on a time plays from there.
struct PlayerLinesStrip: View {
    @Environment(CommonEnvironment.self) private var common
    let model: PlaybackModel
    /// Scrolled by hand: stays put until Back to Now.
    @State private var follows = true
    /// A finger is on the strip (or just was): following waits, so a tap lands on the word under it.
    @State private var touchedAt: Date?

    var body: some View {
        let cues = model.subtitles?.cues ?? []
        let current = model.subtitles?.currentOrPrevious(at: model.mpv.timePosition)?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(cues) { cue in
                        row(cue, isCurrent: cue.id == current).id(cue.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { old, phase in
                if phase == .interacting || (old == .tracking && phase == .decelerating) { follows = false }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in touchedAt = .now }.onEnded { _ in touchedAt = .now })
            .onChange(of: current) { _, id in
                guard follows, let id, !isTouched else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .onChange(of: follows) { _, follows in
                guard follows, let current else { return }
                withAnimation { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .task {
                // Once the lazy rows exist (a scroll right away can miss).
                try? await Task.sleep(for: .milliseconds(150))
                if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
            .overlay(alignment: .bottom) {
                if !follows {
                    Button { follows = true } label: {
                        Label("Back to Now", systemImage: "arrow.down.to.line")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("player.linesBackToNow")
                }
            }
            .overlay {
                if cues.isEmpty {
                    Text(model.subtitleState == .loading ? "Loading subtitles…" : "No Japanese subtitles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("player.lines")
    }

    /// Touched within the last 2 seconds.
    private var isTouched: Bool {
        touchedAt.map { Date.now.timeIntervalSince($0) < 2 } ?? false
    }

    private func row(_ cue: SubtitleCue, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { model.mpv.seek(to: cue.start) } label: {
                Text(TranscriptView.timestamp(cue.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play from \(TranscriptView.timestamp(cue.start))")
            .accessibilityIdentifier("player.lineTime")
            TappableLine(text: cue.text, highlighted: model.highlight?.cue == cue.id ? model.highlight?.range : nil,
                         marks: common.wordMarks.marks(for: cue.sentence), fontSize: isCurrent ? 21 : 19,
                         style: .plain, alignment: .leading) { index in
                model.lookUp(cue, characterIndex: index)
            }
            .fontWeight(isCurrent ? .bold : .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? Color("AccentColor").opacity(0.18) : .clear, in: .rect(cornerRadius: 12))
    }
}
