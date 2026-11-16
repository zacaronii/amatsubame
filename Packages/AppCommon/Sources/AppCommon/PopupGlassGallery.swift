#if DEBUG
import Dictionary
import Lookup
import SwiftUI

/// UI tests: the lookup popup over a chosen background at a chosen opacity, for screenshots of
/// the popup glass (`UITEST_POPUP_GLASS=white|busy`, `UITEST_POPUP_OPACITY=0…100`). The result is
/// built in, so it needs no dictionary (the same on a simulator and a device).
public struct PopupGlassGallery: View {
    public enum Backdrop: String {
        /// A book page: black text on white.
        case white
        /// A dark, busy picture: neon colours, a sign and a white card of text.
        case busy
    }

    @Environment(CommonEnvironment.self) private var environment
    let backdrop: Backdrop
    let opacity: Int
    @State private var popup: LookupPopupModel?

    public init(backdrop: Backdrop, opacity: Int) {
        self.backdrop = backdrop
        self.opacity = opacity
    }

    public static func fromEnvironment() -> PopupGlassGallery? {
        let env = ProcessInfo.processInfo.environment
        guard let backdrop = env["UITEST_POPUP_GLASS"].flatMap(Backdrop.init(rawValue:)) else { return nil }
        return PopupGlassGallery(backdrop: backdrop, opacity: env["UITEST_POPUP_OPACITY"].flatMap(Int.init) ?? 85)
    }

    public var body: some View {
        background
            .ignoresSafeArea()
            .lookupOverlay(popup, service: environment.lookup, onClose: {}) { model in
                LookupPopupView(service: environment.lookup, model: model, drawsBackground: false)
            }
            .overlay(alignment: .topTrailing) {
                Text("\(opacity)%")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white, in: .capsule)
                    .foregroundStyle(.black)
                    .padding()
                    .accessibilityIdentifier("glass.label")
            }
            .task {
                environment.lookup.updatePopupSettings { $0.backgroundOpacityPercent = opacity }
                popup = LookupPopupModel(page: Self.sample)
            }
    }

    @ViewBuilder private var background: some View {
        switch backdrop {
        case .white:
            ZStack(alignment: .topLeading) {
                Color.white
                Text(Self.text + Self.text)
                    .font(.system(size: 19))
                    .lineSpacing(10)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.top, 70)
            }
        case .busy:
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.11, blue: 0.24), Color(red: 0.08, green: 0.09, blue: 0.15),
                                        Color(red: 0.23, green: 0.14, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(Array(Self.lights.enumerated()), id: \.offset) { _, light in
                    Ellipse()
                        .fill(RadialGradient(colors: [light.color, light.color.opacity(0)], center: .center, startRadius: 0, endRadius: light.size.width / 2))
                        .frame(width: light.size.width, height: light.size.height)
                        .position(x: light.at.x, y: light.at.y)
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text("NEON 新宿 · 24H 営業中").font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                    Text("ラーメン　焼き鳥　カラオケ").font(.system(size: 24, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.25, blue: 0.64))
                    Text(Self.text)
                        .font(.system(size: 17))
                        .foregroundStyle(.black)
                        .padding(16)
                        .background(Color(white: 0.98), in: .rect(cornerRadius: 14))
                    Text("いらっしゃいませ！").font(.system(size: 28, weight: .bold)).foregroundStyle(Color(red: 0.27, green: 0.78, blue: 1))
                    Text(Self.text).font(.system(size: 17)).foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 22)
                .padding(.top, 70)
            }
        }
    }

    private struct Light {
        var color: Color
        var at: CGPoint
        var size: CGSize
    }

    private static let lights = [
        Light(color: Color(red: 1, green: 0.25, blue: 0.64), at: CGPoint(x: 70, y: 260), size: CGSize(width: 180, height: 260)),
        Light(color: Color(red: 0.27, green: 0.78, blue: 1), at: CGPoint(x: 320, y: 200), size: CGSize(width: 220, height: 320)),
        Light(color: Color(red: 1, green: 0.69, blue: 0.25), at: CGPoint(x: 250, y: 520), size: CGSize(width: 300, height: 180)),
        Light(color: Color(red: 0.71, green: 0.42, blue: 1), at: CGPoint(x: 150, y: 680), size: CGSize(width: 140, height: 380)),
        Light(color: Color(red: 1, green: 0.25, blue: 0.64), at: CGPoint(x: 340, y: 780), size: CGSize(width: 200, height: 200)),
    ]

    private static let text = "その日の朝、私はいつものように駅前の店で朝ごはんを食べた。白い紙に書かれた文字が並んでいる。窓の外では雨が降り始めていた。"

    /// 食べる as a tap on 食べた: reading, inflection, tags, a frequency, a lookup count and an example.
    static let sample: LookupResultPage = {
        let glossary = #"""
        [{"type":"structured-content","content":[
          {"tag":"ul","data":{"content":"glossary"},"content":[{"tag":"li","content":"to eat"},{"tag":"li","content":"to live on (e.g. a salary); to live off; to subsist on"}]},
          {"tag":"div","data":{"content":"examples"},"content":{"tag":"ul","content":[
            {"tag":"li","lang":"ja","content":["朝ごはんを",{"tag":"span","data":{"content":"example-keyword"},"content":"食べる"},"。"]},
            {"tag":"li","lang":"en","content":"To eat breakfast."}]}}]}]
        """#
        let result = TermLookupResult(
            matched: "食べた", deinflected: "食べる", expression: "食べる", reading: "たべる", rules: ["v1", "vt"],
            inflections: [Inflection(name: "-た", description: "past")],
            glossaries: [Glossary(dictionary: "Jitendex.org [2026-10-03]", json: glossary, definitionTags: ["v1", "vt"], termTags: ["★"])],
            frequencies: [FrequencyGroup(dictionary: "Jiten", values: [Frequency(value: 240, display: "240")])]
        )
        return LookupResultPage(query: "食べた", sentence: text, results: [result], lookupCount: 3)
    }()
}
#endif
