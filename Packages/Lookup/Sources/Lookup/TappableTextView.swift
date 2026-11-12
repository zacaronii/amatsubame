import Dictionary
import SwiftUI

/// Plain text rendered with the tap bridge: tapping a character reports the
/// paragraph's text and the character's UTF-16 offset, exactly as readers will.
public struct TappableTextView: View {
    let text: String
    let engine: DictionaryEngine
    let onTap: (_ text: String, _ utf16Offset: Int) -> Void

    public init(text: String, engine: DictionaryEngine, onTap: @escaping (String, Int) -> Void) {
        self.text = text
        self.engine = engine
        self.onTap = onTap
    }

    public var body: some View {
        LookupWebView(html: Self.document(text), engine: engine) { event in
            if case .tap(let text, let offset) = event { onTap(text, offset) }
        }
    }

    static func document(_ text: String) -> String {
        let paragraphs = text.split(whereSeparator: \.isNewline).map { "<p lang=\"ja\">\(HTML.escape(String($0)))</p>" }.joined()
        return LookupPage.document(
            body: "<div class=\"tappable-text\">\(paragraphs)</div>",
            dictionaryStyles: [:],
            extraCSS: ".tappable-text p { font-size: 1.3em; line-height: 1.8; margin: 0 0 0.6em; }"
        )
    }
}
