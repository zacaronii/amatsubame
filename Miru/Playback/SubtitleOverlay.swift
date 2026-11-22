import AppCommon
import PlayerKit
import SwiftUI

/// The Japanese lines on screen, drawn by the app (not mpv) so every character can be
/// tapped. A tap reports the character's index in the cue's one-line `sentence`.
struct SubtitleOverlay: View {
    @Environment(CommonEnvironment.self) private var common
    let cues: [SubtitleCue]
    var highlight: (cue: Int, range: Range<Int>)?
    var fontSize: CGFloat
    let onTap: (SubtitleCue, Int) -> Void
    /// Swiping the line: +1 = next line (swipe left), −1 = previous (swipe right).
    var onSwipe: ((Int) -> Void)?
    /// Listening first: each line is blurred until it's tapped (or pointed at on the Mac).
    var concealed = false
    /// The pointer came onto the lines, or left them (the Mac: pause while reading).
    var onHover: ((Bool) -> Void)?
    /// The lines shown so far, by cue.
    @State private var revealed: Set<Int> = []

    var body: some View {
        VStack(spacing: 4) {
            ForEach(cues) { cue in
                let hidden = concealed && !revealed.contains(cue.id) && highlight?.cue != cue.id
                TappableLine(text: cue.text, highlighted: highlight?.cue == cue.id ? highlight?.range : nil,
                             marks: common.wordMarks.marks(for: cue.sentence), fontSize: fontSize, style: .overlay) { index in
                    onTap(cue, index)
                }
                .blur(radius: hidden ? fontSize * 0.45 : 0)
                .allowsHitTesting(!hidden)
                .overlay {
                    if hidden {
                        // The first tap only shows the line; the next one looks a word up.
                        Color.clear.contentShape(.rect)
                            .onTapGesture { revealed.insert(cue.id) }
                            .accessibilityLabel("Show the line")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("subtitle.reveal")
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hidden)
            }
        }
        .padding(.horizontal, 8)
        #if os(macOS)
        .onHover { inside in
            if inside, concealed { revealed.formUnion(cues.map(\.id)) }
            onHover?(inside)
        }
        #endif
        // Only the lines on screen are remembered.
        .onChange(of: cues.map(\.id)) { _, ids in revealed.formIntersection(ids) }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > abs(value.translation.height), abs(dx) >= 40 else { return }
                    onSwipe?(dx < 0 ? 1 : -1)
                }
        )
    }
}
