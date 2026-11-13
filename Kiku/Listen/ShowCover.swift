import AppCommon
import SwiftUI

/// A show's (or episode's) square artwork from Audiobookshelf.
struct ShowCover: View {
    @Environment(KikuEnvironment.self) private var environment
    let itemId: String
    var cornerRadius: CGFloat = 8
    /// Called once the image has loaded (show pages tint their header from it).
    var onImage: ((CGImage) -> Void)?
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .task(id: "\(itemId)#\(CoverGeneration.shared.value)") {
                guard let client = environment.audiobookshelfClient(),
                      let request = try? await client.coverRequest(itemId: itemId, width: 600) else { return }
                await CoverLoader.load(request, maxPixelSize: 600) {
                    image = $0
                    onImage?($0)
                }
            }
            .accessibilityHidden(true)
    }
}
