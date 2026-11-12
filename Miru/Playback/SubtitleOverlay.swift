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

    var body: some View {
        VStack(spacing: 4) {
            ForEach(cues) { cue in
                TappableLine(text: cue.text, highlighted: highlight?.cue == cue.id ? highlight?.range : nil,
                             marks: common.wordMarks.marks(for: cue.sentence), fontSize: fontSize, style: .overlay) { index in
                    onTap(cue, index)
                }
            }
        }
        .padding(.horizontal, 8)
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
