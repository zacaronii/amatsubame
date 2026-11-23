import SwiftUI

/// Auto-scroll's controls, at the bottom of the reader while it's on: play or pause, slower and
/// faster with the speed between them, and close. No animation of its own (Reduce Motion or not).
struct AutoScrollCapsule: View {
    let autoScroll: AutoScroll
    /// The speed as shown ("5", "300 字/分") and as VoiceOver reads it.
    let speed: String
    let spokenSpeed: String
    let canSlowDown: Bool
    let canSpeedUp: Bool
    let slower: () -> Void
    let faster: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button(autoScroll.isOn ? "pause.fill" : "play.fill", autoScroll.isOn ? "Pause Auto-Scroll" : "Auto-Scroll", id: "autoScroll.playPause") {
                autoScroll.isOn ? autoScroll.stop() : autoScroll.start()
            }
            button("minus", "Slower", id: "autoScroll.slower") { autoScroll.noteInput(); slower() }
                .disabled(!canSlowDown)
            Text(speed)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 64)
                .accessibilityLabel("Speed")
                .accessibilityValue(spokenSpeed)
                .accessibilityIdentifier("autoScroll.speed")
            button("plus", "Faster", id: "autoScroll.faster") { autoScroll.noteInput(); faster() }
                .disabled(!canSpeedUp)
            Divider().frame(height: 24)
            button("xmark", "Close Auto-Scroll", id: "autoScroll.close") { autoScroll.close() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .overlay(alignment: .top) {
            if autoScroll.stoppedIdle {
                Text("Stopped after \(Int(AutoScroll.idleLimit / 60)) minutes without a touch")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                    .fixedSize()
                    .offset(y: -34)
                    .accessibilityIdentifier("autoScroll.stoppedIdle")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto-Scroll")
    }

    /// An icon with a full 44-point target, so the buttons side by side are each easy to hit.
    private func button(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
